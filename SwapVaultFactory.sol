// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./VaultKey.sol";

/**
 * @title SwapVaultFactory
 * @notice Protocolo de conditional swaps descentralizado
 * @dev Usuários depositam tokens, recebem VaultKey, outros podem exercer manualmente
 * 
 * Características principais:
 * - Qualquer par ERC-20 (ETH/USDT, USDT/ETH, WBTC/ETH, etc)
 * - Exercício MANUAL pelo detentor de VaultKey
 * - SEM oráculos - decisão 100% do usuário
 * - VaultKey fracionável e negociável (100 VKs por vault)
 * - Taxa cobrada de quem exerce (não de quem cria)
 * - Taxa travada por vault no momento da criação
 * - Proteção contra tokens com fee-on-transfer
 * - Mecanismo de emergência para finalização
 */
contract SwapVaultFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ============ Constantes ============
    
    /// @notice Quantidade fixa de VaultKeys criadas por vault (100 com 18 decimais)
    uint256 public constant VAULT_KEY_SUPPLY = 100 * 1e18;
    
    /// @notice Taxa máxima permitida (1%)
    uint256 public constant MAX_FEE = 100;
    
    /// @notice Tempo mínimo de expiração (15 minutos)
    uint256 public constant MIN_EXPIRATION = 15 minutes;
    
    /// @notice Tempo máximo de expiração (3 anos)
    uint256 public constant MAX_EXPIRATION = 1095 days;
    
    /// @notice Delay para finalização de emergência após expiração (30 dias)
    uint256 public constant EMERGENCY_DELAY = 30 days;
    
    // ============ Estruturas ============
    
    struct Vault {
        address creator;              // Criador do vault (recebe tokenRequired no exercício)
        address tokenDeposited;       // Token depositado pelo criador
        uint256 amountDeposited;      // Quantidade REAL depositada (após fee-on-transfer)
        address tokenRequired;        // Token necessário para exercer
        uint256 amountRequired;       // Quantidade necessária para exercício total
        uint256 expiration;           // Timestamp de expiração
        address vaultKeyAddress;      // Endereço do token VaultKey
        uint256 amountExercised;      // Quantidade já exercida (em unidades do tokenDeposited)
        bool finalized;               // True se vault foi finalizado após expiração
        uint256 lockedTakerFee;       // Taxa do taker travada na criação (basis points) — adicional sobre amountRequired
        uint256 lockedMakerFee;       // Taxa do maker travada na criação (basis points) — deduzida do que o criador recebe
    }
    
    // ============ Variáveis de Estado ============
    
    /// @notice Mapping de ID do vault para seus dados
    mapping(uint256 => Vault) public vaults;
    
    /// @notice Contador de vaults criados
    uint256 public vaultCounter;
    
    /// @notice Taxa cobrada do taker no exercício (adicional sobre amountRequired)
    uint256 public takerFee;

    /// @notice Taxa cobrada do maker no exercício (deduzida do que o criador recebe)
    uint256 public makerFee;
    
    /// @notice Endereço que recebe as taxas
    address public feeCollector;
    
    // ============ Eventos ============
    
    event VaultCreated(
        uint256 indexed vaultId,
        address indexed creator,
        address tokenDeposited,
        uint256 amountDeposited,
        address tokenRequired,
        uint256 amountRequired,
        uint256 expiration,
        address vaultKeyAddress,
        uint256 lockedTakerFee,
        uint256 lockedMakerFee
    );

    event VaultExercised(
        uint256 indexed vaultId,
        address indexed exerciser,
        uint256 vaultKeyAmount,
        uint256 tokenRequiredAmount,
        uint256 tokenDepositedAmount,
        uint256 takerFeeAmount,
        uint256 makerFeeAmount
    );
    
    event VaultFinalized(
        uint256 indexed vaultId,
        address indexed finalizer,
        uint256 amountReturned
    );
    
    event EmergencyFinalized(
        uint256 indexed vaultId,
        address indexed finalizer,
        uint256 amountReturned
    );
    
    event TakerFeeUpdated(uint256 oldFee, uint256 newFee);
    event MakerFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    
    // ============ Errors Customizados ============
    
    error InvalidToken();
    error InvalidAmount();
    error InvalidExpiration();
    error SameToken();
    error VaultExpired();
    error VaultNotExpired();
    error VaultAlreadyFinalized();
    error InsufficientVaultKey();
    error OnlyCreatorOrVaultKeyHolder();
    error EmergencyDelayNotReached();
    error OnlyFeeCollector();
    error FeeTooHigh();
    error ZeroAddress();
    error FeeOnTransferNotSupported();
    
    // ============ Constructor ============
    
    /**
     * @notice Inicializa o contrato
     * @param _feeCollector Endereço que receberá as taxas do protocolo
     */
    constructor(address _feeCollector) {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
        takerFee = 0;
        makerFee = 0;
    }
    
    // ============ Funções Principais ============
    
    /**
     * @notice Cria um novo vault de swap condicional
     * @param _tokenDeposited Token a ser depositado pelo criador
     * @param _amountDeposited Quantidade a depositar
     * @param _tokenRequired Token necessário para exercer
     * @param _amountRequired Quantidade necessária para exercício completo
     * @param _expiration Timestamp de expiração do vault
     * @return vaultId ID do vault criado
     * 
     * @dev O criador deve ter aprovado _amountDeposited de _tokenDeposited antes
     * @dev Retorna 100 VaultKey ERC-20 (cada VK = 1% do vault)
     * @dev Rejeita tokens com fee-on-transfer (amount recebido deve ser exato)
     * @dev A taxa do protocolo é travada no momento da criação
     */
    function createVault(
        address _tokenDeposited,
        uint256 _amountDeposited,
        address _tokenRequired,
        uint256 _amountRequired,
        uint256 _expiration
    ) external nonReentrant returns (uint256 vaultId) {
        // Validações
        if (_tokenDeposited == address(0) || _tokenRequired == address(0)) {
            revert InvalidToken();
        }
        if (_tokenDeposited == _tokenRequired) {
            revert SameToken();
        }
        if (_amountDeposited == 0 || _amountRequired == 0) {
            revert InvalidAmount();
        }
        
        // Validar expiração explicitamente (evita underflow)
        if (_expiration <= block.timestamp) {
            revert InvalidExpiration();
        }
        uint256 timeUntilExpiration = _expiration - block.timestamp;
        if (timeUntilExpiration < MIN_EXPIRATION || timeUntilExpiration > MAX_EXPIRATION) {
            revert InvalidExpiration();
        }
        
        // Gerar ID único para o vault
        vaultId = vaultCounter++;
        
        // Criar VaultKey token (100 VKs fixas)
        string memory vaultKeyName = string(
            abi.encodePacked("VaultKey #", _uintToString(vaultId))
        );
        string memory vaultKeySymbol = string(
            abi.encodePacked("VK-", _uintToString(vaultId))
        );
        
        VaultKey vaultKey = new VaultKey(
            vaultKeyName,
            vaultKeySymbol,
            msg.sender,
            VAULT_KEY_SUPPLY,  // Sempre 100 VKs (com 18 decimais)
            vaultId
        );
        
        // Proteção contra fee-on-transfer:
        // Medir saldo antes e depois da transferência
        uint256 balanceBefore = IERC20(_tokenDeposited).balanceOf(address(this));
        
        IERC20(_tokenDeposited).safeTransferFrom(
            msg.sender,
            address(this),
            _amountDeposited
        );
        
        uint256 balanceAfter = IERC20(_tokenDeposited).balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;
        
        // Rejeitar tokens com fee-on-transfer
        if (actualReceived != _amountDeposited) {
            revert FeeOnTransferNotSupported();
        }
        
        // Armazenar dados do vault (com fees travadas)
        vaults[vaultId] = Vault({
            creator: msg.sender,
            tokenDeposited: _tokenDeposited,
            amountDeposited: _amountDeposited,
            tokenRequired: _tokenRequired,
            amountRequired: _amountRequired,
            expiration: _expiration,
            vaultKeyAddress: address(vaultKey),
            amountExercised: 0,
            finalized: false,
            lockedTakerFee: takerFee,
            lockedMakerFee: makerFee
        });

        emit VaultCreated(
            vaultId,
            msg.sender,
            _tokenDeposited,
            _amountDeposited,
            _tokenRequired,
            _amountRequired,
            _expiration,
            address(vaultKey),
            takerFee,
            makerFee
        );
        
        return vaultId;
    }
    
    /**
     * @notice Exerce um vault depositando tokens e queimando VaultKey
     * @param _vaultId ID do vault a exercer
     * @param _vaultKeyAmount Quantidade de VaultKey a queimar (proporcional ao exercício)
     * 
     * @dev Exercício é MANUAL - usuário decide quando exercer
     * @dev Proporção: _vaultKeyAmount / VAULT_KEY_SUPPLY (100 VKs = 100% do vault)
     * @dev 1 VK inteiro = 1% do vault. Frações de VK são permitidas.
     * @dev Taxa usa lockedFee do vault (travada na criação), não a taxa atual
     * @dev Requer:
     *      1. Posse de VaultKey
     *      2. Aprovação de tokenRequired (incluindo taxa)
     *      3. Vault não expirado
     */
    function exercise(
        uint256 _vaultId,
        uint256 _vaultKeyAmount
    ) external nonReentrant {
        Vault storage vault = vaults[_vaultId];
        
        // Validações
        if (block.timestamp >= vault.expiration) revert VaultExpired();
        if (vault.finalized) revert VaultAlreadyFinalized();
        if (_vaultKeyAmount == 0) revert InvalidAmount();
        
        // Calcular quantidade de tokenDeposited proporcional às VKs
        // Proporção: _vaultKeyAmount / VAULT_KEY_SUPPLY * amountDeposited
        uint256 depositedAmount = (_vaultKeyAmount * vault.amountDeposited) / VAULT_KEY_SUPPLY;
        
        // Verificar se há saldo suficiente no vault
        uint256 remainingDeposited = vault.amountDeposited - vault.amountExercised;
        if (depositedAmount > remainingDeposited) revert InsufficientVaultKey();
        
        // Calcular quantidade de tokenRequired proporcional
        uint256 requiredAmount = (_vaultKeyAmount * vault.amountRequired) / VAULT_KEY_SUPPLY;
        
        // Calcular taxas usando fees travadas na criação do vault
        uint256 takerFeeAmount    = (requiredAmount * vault.lockedTakerFee) / 10000;
        uint256 makerFeeAmount    = (requiredAmount * vault.lockedMakerFee) / 10000;
        uint256 totalFromTaker    = requiredAmount + takerFeeAmount;
        uint256 makerReceives     = requiredAmount - makerFeeAmount;
        uint256 totalFeeToCollector = takerFeeAmount + makerFeeAmount;

        // Atualizar estado do vault
        vault.amountExercised += depositedAmount;

        // Queimar VaultKey do exercitador
        VaultKey(vault.vaultKeyAddress).burn(msg.sender, _vaultKeyAmount);

        // Receber tokenRequired do taker (inclui taker fee)
        IERC20(vault.tokenRequired).safeTransferFrom(msg.sender, address(this), totalFromTaker);

        // Repassar valor líquido ao maker
        if (makerReceives > 0) {
            IERC20(vault.tokenRequired).safeTransfer(vault.creator, makerReceives);
        }

        // Repassar taxas ao feeCollector
        if (totalFeeToCollector > 0) {
            IERC20(vault.tokenRequired).safeTransfer(feeCollector, totalFeeToCollector);
        }

        // Entregar tokenDeposited ao taker
        IERC20(vault.tokenDeposited).safeTransfer(msg.sender, depositedAmount);

        emit VaultExercised(
            _vaultId,
            msg.sender,
            _vaultKeyAmount,
            totalFromTaker,
            depositedAmount,
            takerFeeAmount,
            makerFeeAmount
        );
    }
    
    /**
     * @notice Finaliza vault expirado e retorna tokens não exercidos ao criador
     * @param _vaultId ID do vault a finalizar
     * 
     * @dev Apenas o criador ou detentores de VaultKey podem finalizar
     * @dev Tokens restantes sempre vão para o criador
     */
    function finalizeVault(uint256 _vaultId) external nonReentrant {
        Vault storage vault = vaults[_vaultId];
        
        // Validações
        if (block.timestamp < vault.expiration) revert VaultNotExpired();
        if (vault.finalized) revert VaultAlreadyFinalized();
        
        // Apenas criador ou detentor de VaultKey pode finalizar
        bool isCreator = msg.sender == vault.creator;
        bool isVaultKeyHolder = IERC20(vault.vaultKeyAddress).balanceOf(msg.sender) > 0;
        if (!isCreator && !isVaultKeyHolder) {
            revert OnlyCreatorOrVaultKeyHolder();
        }
        
        // Calcular quantidade restante
        uint256 remainingAmount = vault.amountDeposited - vault.amountExercised;
        
        // Marcar como finalizado
        vault.finalized = true;
        
        // Retornar tokens restantes ao criador
        if (remainingAmount > 0) {
            IERC20(vault.tokenDeposited).safeTransfer(
                vault.creator,
                remainingAmount
            );
        }
        
        emit VaultFinalized(_vaultId, msg.sender, remainingAmount);
    }
    
    /**
     * @notice Finalização de emergência - qualquer pessoa pode finalizar após delay
     * @param _vaultId ID do vault a finalizar
     * 
     * @dev Pode ser chamado por qualquer um após expiração + EMERGENCY_DELAY (30 dias)
     * @dev Previne tokens travados permanentemente caso criador perca acesso
     */
    function emergencyFinalize(uint256 _vaultId) external nonReentrant {
        Vault storage vault = vaults[_vaultId];
        
        // Validações
        if (vault.finalized) revert VaultAlreadyFinalized();
        if (block.timestamp < vault.expiration + EMERGENCY_DELAY) {
            revert EmergencyDelayNotReached();
        }
        
        // Calcular quantidade restante
        uint256 remainingAmount = vault.amountDeposited - vault.amountExercised;
        
        // Marcar como finalizado
        vault.finalized = true;
        
        // Retornar tokens restantes ao criador
        if (remainingAmount > 0) {
            IERC20(vault.tokenDeposited).safeTransfer(
                vault.creator,
                remainingAmount
            );
        }
        
        emit EmergencyFinalized(_vaultId, msg.sender, remainingAmount);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Retorna dados completos de um vault
     * @param _vaultId ID do vault
     * @return Struct Vault com todos os dados
     */
    function getVault(uint256 _vaultId) external view returns (Vault memory) {
        return vaults[_vaultId];
    }
    
    /**
     * @notice Calcula quantidades para exercício
     * @param _vaultId ID do vault
     * @param _vaultKeyAmount Quantidade de VaultKey a exercer
     * @return requiredAmount Quantidade de tokenRequired (sem taxas)
     * @return depositedAmount Quantidade de tokenDeposited a receber
     * @return takerFeeAmount Taxa adicional paga pelo taker
     * @return makerFeeAmount Taxa deduzida do que o maker recebe
     * @return totalFromTaker Total que o taker precisa aprovar
     * @return makerReceives Total que o maker efetivamente recebe
     */
    function calculateExerciseAmounts(
        uint256 _vaultId,
        uint256 _vaultKeyAmount
    ) external view returns (
        uint256 requiredAmount,
        uint256 depositedAmount,
        uint256 takerFeeAmount,
        uint256 makerFeeAmount,
        uint256 totalFromTaker,
        uint256 makerReceives
    ) {
        Vault memory vault = vaults[_vaultId];

        depositedAmount  = (_vaultKeyAmount * vault.amountDeposited) / VAULT_KEY_SUPPLY;
        requiredAmount   = (_vaultKeyAmount * vault.amountRequired)  / VAULT_KEY_SUPPLY;
        takerFeeAmount   = (requiredAmount  * vault.lockedTakerFee)  / 10000;
        makerFeeAmount   = (requiredAmount  * vault.lockedMakerFee)  / 10000;
        totalFromTaker   = requiredAmount + takerFeeAmount;
        makerReceives    = requiredAmount - makerFeeAmount;
    }
    
    /**
     * @notice Verifica se vault está ativo
     * @param _vaultId ID do vault
     * @return bool True se ativo (não expirado, não finalizado, tem saldo)
     */
    function isVaultActive(uint256 _vaultId) external view returns (bool) {
        Vault memory vault = vaults[_vaultId];
        return block.timestamp < vault.expiration && 
               !vault.finalized && 
               vault.amountExercised < vault.amountDeposited;
    }
    
    /**
     * @notice Retorna quantidade restante exercível
     * @param _vaultId ID do vault
     * @return uint256 Quantidade restante de tokenDeposited
     */
    function getRemainingAmount(uint256 _vaultId) external view returns (uint256) {
        Vault memory vault = vaults[_vaultId];
        return vault.amountDeposited - vault.amountExercised;
    }
    
    /**
     * @notice Retorna taxa strike por unidade (com 18 decimais de precisão)
     * @param _vaultId ID do vault
     * @return uint256 Strike price = amountRequired * 1e18 / amountDeposited
     */
    function getStrikePrice(uint256 _vaultId) external view returns (uint256) {
        Vault memory vault = vaults[_vaultId];
        return (vault.amountRequired * 1e18) / vault.amountDeposited;
    }
    
    /**
     * @notice Retorna tempo restante até expiração
     * @param _vaultId ID do vault
     * @return uint256 Segundos até expiração (0 se já expirou)
     */
    function getTimeToExpiration(uint256 _vaultId) external view returns (uint256) {
        Vault memory vault = vaults[_vaultId];
        if (block.timestamp >= vault.expiration) {
            return 0;
        }
        return vault.expiration - block.timestamp;
    }
    
    // ============ Funções Admin ============
    
    /**
     * @notice Atualiza taker fee (afeta apenas vaults FUTUROS)
     * @param _newFee Nova taxa em basis points (máx 100 = 1%)
     */
    function updateTakerFee(uint256 _newFee) external {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (_newFee > MAX_FEE) revert FeeTooHigh();
        uint256 oldFee = takerFee;
        takerFee = _newFee;
        emit TakerFeeUpdated(oldFee, _newFee);
    }

    /**
     * @notice Atualiza maker fee (afeta apenas vaults FUTUROS)
     * @param _newFee Nova taxa em basis points (máx 100 = 1%)
     */
    function updateMakerFee(uint256 _newFee) external {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (_newFee > MAX_FEE) revert FeeTooHigh();
        uint256 oldFee = makerFee;
        makerFee = _newFee;
        emit MakerFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @notice Atualiza endereço do fee collector
     * @param _newCollector Novo endereço
     */
    function updateFeeCollector(address _newCollector) external {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (_newCollector == address(0)) revert ZeroAddress();
        
        address oldCollector = feeCollector;
        feeCollector = _newCollector;
        
        emit FeeCollectorUpdated(oldCollector, _newCollector);
    }
    
    // ============ Funções Helper Internas ============
    
    /**
     * @dev Converte uint para string
     */
    function _uintToString(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }
}
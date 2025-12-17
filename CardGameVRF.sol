// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Chainlink VRF v2.5
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract CardGameVRF is VRFConsumerBaseV2Plus, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ====== 게임 토큰/룰 ======
    IERC20 public immutable SABU;
    uint256 public immutable entryFee;   // 참가비(예치금에서 차감)
    uint256 public immutable reward;     // 승리 시 당첨금(적립)
    uint256 public constant WITHDRAW_FEE_BPS = 500; // 당첨금 출금 시에만 5%

    // ====== VRF 설정 ======
    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;
    uint16  public immutable requestConfirmations;
    uint32  public immutable callbackGasLimit;
    bool    public payWithNative;

    // ====== 릴레이어(가스리스 실행자) ======
    address public relayer;

    // ====== 유저 잔고 ======
    mapping(address => uint256) public deposits; // 예치금(내 돈)
    mapping(address => uint256) public winnings; // 당첨금(출금 시 5% 수수료)
    mapping(address => bool) public hasWon;      // 마지막 결과(UI 용)

    // ====== 하우스 출금 안전장치(잠금) ======
    uint256 public totalDeposits;
    uint256 public totalWinningsOwed;
    uint256 public reservedPending;

    // ====== 세션(유저당 동시 1판) ======
    enum State { NONE, WAITING_VRF }
    struct Session {
        State state;
        bool choiceBlue;
        uint256 requestId;
        uint64 startedAt;
        uint256 reserved; // max(entryFee, reward)
    }
    mapping(address => Session) public sessions;
    mapping(uint256 => address) public requestToPlayer;

    uint256 public immutable timeoutSeconds;

    // ====== 서명 기반 게임 시작 ======
    struct PlayIntent {
        address player;
        bool choiceBlue;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 private constant PLAY_TYPEHASH =
        keccak256("PlayIntent(address player,bool choiceBlue,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) public nonces;

    // ====== 이벤트 ======
    event RelayerSet(address indexed relayer);
    event Deposited(address indexed player, uint256 received);
    event DepositWithdrawn(address indexed player, uint256 amount);

    event GameStarted(address indexed player, uint256 indexed requestId, bool choiceBlue);
    event GameResolved(
        address indexed player,
        uint256 indexed requestId,
        uint256 blueNumber,
        uint256 redNumber,
        bool win,
        bool tie
    );

    event WinningsWithdrawn(address indexed player, uint256 gross, uint256 fee, uint256 net);
    event HouseWithdrawn(address indexed to, uint256 amount);
    event NativePaymentModeSet(bool enabled);
    event GameTimeoutRefund(address indexed player, uint256 indexed requestId);

    constructor(
        address sabuToken,
        uint256 _entryFee,
        uint256 _reward,
        address vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _payWithNative,
        uint256 _timeoutSeconds,
        address _relayer
    )
        VRFConsumerBaseV2Plus(vrfCoordinator)
        EIP712("CardGameVRF", "1")
    {
        require(sabuToken != address(0), "SABU=0");
        require(_entryFee > 0 && _reward > 0, "bad rule");
        require(_timeoutSeconds >= 60, "timeout too small");
        require(_relayer != address(0), "relayer=0");

        SABU = IERC20(sabuToken);
        entryFee = _entryFee;
        reward = _reward;

        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        payWithNative = _payWithNative;

        timeoutSeconds = _timeoutSeconds;

        relayer = _relayer;
        emit RelayerSet(_relayer);
    }

    // ====== 관리자 (onlyOwner는 VRFConsumerBaseV2Plus -> ConfirmedOwnerWithProposal에서 제공) ======
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setPayWithNative(bool enabled) external onlyOwner {
        payWithNative = enabled;
        emit NativePaymentModeSet(enabled);
    }

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "relayer=0");
        relayer = newRelayer;
        emit RelayerSet(newRelayer);
    }

    // 하우스 출금 가능 금액 = 잔액 - (예치금 + 당첨금 채무 + VRF 대기 예약금)
    function availableHouseBalance() public view returns (uint256) {
        uint256 bal = SABU.balanceOf(address(this));
        uint256 locked = totalDeposits + totalWinningsOwed + reservedPending;
        return bal > locked ? bal - locked : 0;
    }

    function withdrawHouse(address to, uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(to != address(0), "to=0");
        require(amount <= availableHouseBalance(), "exceeds available");
        SABU.safeTransfer(to, amount);
        emit HouseWithdrawn(to, amount);
    }

    // ====== 유저: 예치/출금 ======
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "amount=0");

        uint256 beforeBal = SABU.balanceOf(address(this));
        SABU.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = SABU.balanceOf(address(this));

        uint256 received = afterBal - beforeBal;
        require(received > 0, "received=0");

        deposits[msg.sender] += received;
        totalDeposits += received;

        emit Deposited(msg.sender, received);
    }

    function withdrawDeposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "amount=0");
        require(deposits[msg.sender] >= amount, "insufficient deposit");

        deposits[msg.sender] -= amount;
        totalDeposits -= amount;

        SABU.safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(msg.sender, amount);
    }

    function withdrawWinnings() external nonReentrant whenNotPaused {
        uint256 gross = winnings[msg.sender];
        require(gross > 0, "no winnings");

        winnings[msg.sender] = 0;
        totalWinningsOwed -= gross;

        uint256 fee = (gross * WITHDRAW_FEE_BPS) / 10_000;
        uint256 net = gross - fee;

        SABU.safeTransfer(msg.sender, net);
        emit WinningsWithdrawn(msg.sender, gross, fee, net);
    }

    // ====== 게임 시작(서명 기반 / 릴레이어 tx) ======
    function startGameWithSig(PlayIntent calldata intent, bytes calldata sig)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        require(msg.sender == relayer, "only relayer");
        require(intent.player != address(0), "player=0");
        require(block.timestamp <= intent.deadline, "sig expired");

        bytes32 structHash = keccak256(
            abi.encode(PLAY_TYPEHASH, intent.player, intent.choiceBlue, intent.nonce, intent.deadline)
        );

        address signer = ECDSA.recover(_hashTypedDataV4(structHash), sig);
        require(signer == intent.player, "bad sig");

        require(intent.nonce == nonces[intent.player], "bad nonce");
        nonces[intent.player]++;

        Session storage s = sessions[intent.player];
        require(s.state == State.NONE, "already in game");

        require(deposits[intent.player] >= entryFee, "deposit < entryFee");
        deposits[intent.player] -= entryFee;
        totalDeposits -= entryFee;

        uint256 perGameReserve = reward > entryFee ? reward : entryFee;

        uint256 bal = SABU.balanceOf(address(this));
        uint256 lockedAfter = totalDeposits + totalWinningsOwed + reservedPending + perGameReserve;
        require(bal >= lockedAfter, "pool insufficient");
        reservedPending += perGameReserve;

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 2,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({ nativePayment: payWithNative })
                )
            })
        );

        sessions[intent.player] = Session({
            state: State.WAITING_VRF,
            choiceBlue: intent.choiceBlue,
            requestId: requestId,
            startedAt: uint64(block.timestamp),
            reserved: perGameReserve
        });

        requestToPlayer[requestId] = intent.player;
        emit GameStarted(intent.player, requestId, intent.choiceBlue);
    }

    // ====== VRF 콜백(결과 확정) ======
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        address player = requestToPlayer[requestId];
        if (player == address(0)) return;

        Session storage s = sessions[player];
        if (s.state != State.WAITING_VRF || s.requestId != requestId) return;

        reservedPending -= s.reserved;

        uint256 blue = randomWords[0] % 10;
        uint256 red  = randomWords[1] % 10;

        bool tie = (blue == red);
        bool win = false;

        if (tie) {
            deposits[player] += entryFee;
            totalDeposits += entryFee;
            hasWon[player] = false;
        } else {
            bool blueWins = (blue > red);
            win = (s.choiceBlue == blueWins);
            hasWon[player] = win;

            if (win) {
                winnings[player] += reward;
                totalWinningsOwed += reward;
            }
        }

        delete sessions[player];
        delete requestToPlayer[requestId];

        emit GameResolved(player, requestId, blue, red, win, tie);
    }

    // VRF 지연 시 환급(무승부 환급과 동일)
    function refundAfterTimeout() external nonReentrant {
        Session storage s = sessions[msg.sender];
        require(s.state == State.WAITING_VRF, "not waiting");
        require(block.timestamp > uint256(s.startedAt) + timeoutSeconds, "not timed out");

        reservedPending -= s.reserved;

        deposits[msg.sender] += entryFee;
        totalDeposits += entryFee;

        uint256 rid = s.requestId;
        delete requestToPlayer[rid];
        delete sessions[msg.sender];

        emit GameTimeoutRefund(msg.sender, rid);
    }
}

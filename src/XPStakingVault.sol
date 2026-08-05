// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWXP} from "./interfaces/IWXP.sol";

/// @title XPStakingVault
/// @notice ERC-4626 vault for staking WXP with a fixed 10^offset:1 share/asset rate,
///         a 7-day async redeem cooldown (ERC-7540 inspired), Synthetix-style reward
///         accrual funded by the RewardDistributor, on-chain partner referral accounting,
///         and a global stake cap. User principal is never re-delegated and is fully
///         segregated from the reward pool, so principal is always 100% withdrawable.
/// @dev totalAssets() is tracked internally (not by token balance), which makes the
///      exchange rate immune to donation/inflation attacks. All share mints and burns
///      are aligned to 10^offset so that totalSupply() == totalStakedAssets * 10^offset
///      holds as a strict equality at all times.
contract XPStakingVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Roles & constants
    // ---------------------------------------------------------------------

    bytes32 public constant PARAM_ADMIN_ROLE = keccak256("PARAM_ADMIN_ROLE");
    bytes32 public constant PARTNER_MANAGER_ROLE = keccak256("PARTNER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    /// @notice Virtual-share decimal offset. Structural constant of the fixed-rate proof.
    uint8 private constant _DECIMALS_OFFSET = 3;
    /// @notice 10^_DECIMALS_OFFSET; every share mint/burn is aligned to this multiple.
    uint256 private constant SHARE_UNIT = 10 ** _DECIMALS_OFFSET;
    /// @notice Reward math precision.
    uint256 private constant PRECISION = 1e18;

    /// @notice Sentinel partner id for principal attributed to no external partner.
    bytes32 public constant PARTNER_DIRECT = keccak256("DIRECT");

    // ---------------------------------------------------------------------
    // Immutable config
    // ---------------------------------------------------------------------

    /// @notice Wrapped XP, the vault asset. Held as both principal and reward reserves.
    IWXP public immutable wxp;
    /// @notice Upper bound for `cooldownPeriod` (anti-hostage guard).
    uint256 public immutable maxCooldown;
    /// @notice Lower bound for `rewardsDuration` (prevents notify division-by-zero).
    uint256 public immutable minRewardsDuration;
    /// @notice Upper bound for `rewardsDuration`.
    uint256 public immutable maxRewardsDuration;

    // ---------------------------------------------------------------------
    // Principal / cap accounting
    // ---------------------------------------------------------------------

    /// @notice Internally tracked principal total. Equals totalAssets().
    uint256 public totalStakedAssets;
    /// @notice Principal owed to in-cooldown redeem requests (shares already burned).
    uint256 public totalPendingRedeemAssets;
    /// @notice Global staking cap (principal basis). May be lowered below current TVL.
    uint256 public stakeCap;

    // ---------------------------------------------------------------------
    // Async redeem
    // ---------------------------------------------------------------------

    /// @notice Unstaking cooldown; only applies to new requests (no retroactive change).
    uint256 public cooldownPeriod;
    uint256 private _nextRequestId;

    struct RedeemRequest {
        address controller;
        uint96 claimableAt;
        uint256 assets;
        bool claimed;
    }

    mapping(uint256 => RedeemRequest) public redeemRequests;
    mapping(address => uint256[]) private _userRequestIds;
    /// @notice ERC-7540 operator approvals: isOperator[controller][operator].
    mapping(address => mapping(address => bool)) public isOperator;

    // ---------------------------------------------------------------------
    // Synthetix reward accrual
    // ---------------------------------------------------------------------

    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /// @notice WXP earmarked as reward reserves (ledger; +on notify, -on claim/sweep).
    uint256 public rewardReserves;
    /// @notice Rewards that streamed while totalSupply()==0 plus notify rounding dust.
    ///         Recoverable only up to this counter; disjoint from user-owed earned rewards.
    uint256 public unallocatedRewards;
    /// @notice Most recent notify amount (currentAPR source).
    uint256 public lastNotifiedReward;
    /// @notice Timestamp of the most recent notify.
    uint256 public lastNotifiedAt;
    /// @notice Measured interval between the last two notifies (currentAPR annualization base).
    uint256 public lastNotifyInterval;
    /// @notice Cumulative rewards claimed by users.
    uint256 public totalRewardsDistributed;

    // ---------------------------------------------------------------------
    // Partner (referral) accounting
    // ---------------------------------------------------------------------

    struct Partner {
        bool active;
        uint256 subCap;
        uint256 tvl;
    }

    mapping(bytes32 => Partner) public partners;
    /// @notice receiver => attributed bucket. 0 = unattributed, PARTNER_DIRECT = direct.
    mapping(address => bytes32) public userPartner;
    /// @notice receiver => principal (all in a single bucket; guarantees no TVL underflow).
    mapping(address => uint256) public userPrincipal;

    /// @notice RewardDistributor address (sweep recipient). Set once post-deploy.
    address public distributor;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Deposited(
        address indexed sender, address indexed receiver, uint256 assets, uint256 shares, bytes32 indexed partnerId
    );
    event RedeemRequested(
        address indexed owner,
        address indexed controller,
        uint256 indexed requestId,
        uint256 shares,
        uint256 assets,
        uint256 claimableAt,
        bytes32 partnerId
    );
    event RedeemClaimed(
        address indexed controller, address indexed receiver, uint256 indexed requestId, uint256 assets, bool native
    );
    event RewardNotified(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event RewardClaimed(address indexed account, address indexed receiver, uint256 amount, bool native);
    event UnallocatedRewardsSwept(uint256 amount);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event StakeCapUpdated(uint256 oldCap, uint256 newCap);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event DistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    event PartnerRegistered(bytes32 indexed partnerId, uint256 subCap);
    event PartnerCapUpdated(bytes32 indexed partnerId, uint256 oldCap, uint256 newCap);
    event PartnerStatusUpdated(bytes32 indexed partnerId, bool active);
    event PartnerReassigned(
        address indexed user, bytes32 indexed oldPartnerId, bytes32 indexed newPartnerId, uint256 principal
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidConfig();
    error TransfersDisabled();
    error AsyncRedeemOnly();
    error SharesNotAligned();
    error ZeroAssets();
    error Unauthorized();
    error UnauthorizedAttribution();
    error InvalidPartner();
    error PartnerNotActive();
    error PartnerMismatch();
    error PartnerCapExceeded();
    error NotAttributed();
    error AlreadyClaimed();
    error CooldownNotElapsed();
    error RewardNotFunded();
    error DistributorNotSet();
    error OnlyWXP();
    error NativeTransferFailed();
    error CannotRecoverAsset();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param wxp_ Wrapped XP contract (vault asset).
    /// @param stakeCap_ Initial global stake cap (principal).
    /// @param cooldownPeriod_ Initial unstaking cooldown (<= maxCooldown_).
    /// @param maxCooldown_ Immutable upper bound for the cooldown.
    /// @param rewardsDuration_ Initial reward streaming window (within [min,max]).
    /// @param minRewardsDuration_ Immutable lower bound (> 0) for the streaming window.
    /// @param maxRewardsDuration_ Immutable upper bound for the streaming window.
    /// @param admin_ Initial holder of DEFAULT_ADMIN_ROLE and all operational roles.
    constructor(
        IWXP wxp_,
        uint256 stakeCap_,
        uint256 cooldownPeriod_,
        uint256 maxCooldown_,
        uint256 rewardsDuration_,
        uint256 minRewardsDuration_,
        uint256 maxRewardsDuration_,
        address admin_
    ) ERC20("Staked XP", "sXP") ERC4626(IERC20(address(wxp_))) {
        if (address(wxp_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (cooldownPeriod_ > maxCooldown_) revert InvalidConfig();
        if (minRewardsDuration_ == 0 || minRewardsDuration_ > maxRewardsDuration_) revert InvalidConfig();
        if (rewardsDuration_ < minRewardsDuration_ || rewardsDuration_ > maxRewardsDuration_) revert InvalidConfig();

        wxp = wxp_;
        stakeCap = stakeCap_;
        cooldownPeriod = cooldownPeriod_;
        maxCooldown = maxCooldown_;
        rewardsDuration = rewardsDuration_;
        minRewardsDuration = minRewardsDuration_;
        maxRewardsDuration = maxRewardsDuration_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ADMIN_ROLE, admin_);
        _grantRole(PARTNER_MANAGER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
    }

    /// @notice Accept native XP only from WXP unwrap (during native claim/redeem/sweep).
    receive() external payable {
        if (msg.sender != address(wxp)) revert OnlyWXP();
    }

    // ---------------------------------------------------------------------
    // ERC-4626 overrides: fixed internal accounting
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        return totalStakedAssets;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return _DECIMALS_OFFSET;
    }

    // ---------------------------------------------------------------------
    // Deposits
    // ---------------------------------------------------------------------

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        shares = _processDeposit(_msgSender(), receiver, assets, true, bytes32(0), false);
    }

    /// @inheritdoc ERC4626
    /// @dev Requires `shares` to be a multiple of 10^offset (fixed-rate invariant).
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares % SHARE_UNIT != 0) revert SharesNotAligned();
        assets = previewMint(shares);
        _processDeposit(_msgSender(), receiver, assets, true, bytes32(0), false);
    }

    /// @notice Deposits native XP, wrapping it into WXP internally.
    /// @param receiver Share recipient.
    /// @return shares Shares minted.
    function depositNative(address receiver) external payable whenNotPaused nonReentrant returns (uint256 shares) {
        wxp.deposit{value: msg.value}();
        shares = _processDeposit(_msgSender(), receiver, msg.value, false, bytes32(0), false);
    }

    /// @notice Deposits WXP and attributes the receiver to `partnerId`.
    function depositWithReferral(uint256 assets, address receiver, bytes32 partnerId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (partnerId == bytes32(0) || partnerId == PARTNER_DIRECT) revert InvalidPartner();
        shares = _processDeposit(_msgSender(), receiver, assets, true, partnerId, true);
    }

    /// @notice Deposits native XP and attributes the receiver to `partnerId`.
    function depositNativeWithReferral(address receiver, bytes32 partnerId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (partnerId == bytes32(0) || partnerId == PARTNER_DIRECT) revert InvalidPartner();
        wxp.deposit{value: msg.value}();
        shares = _processDeposit(_msgSender(), receiver, msg.value, false, partnerId, true);
    }

    function _processDeposit(
        address caller,
        address receiver,
        uint256 assets,
        bool pullFromCaller,
        bytes32 referralPid,
        bool viaReferral
    ) private returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        bytes32 pid = _resolveAttribution(caller, receiver, referralPid, viaReferral);

        uint256 maxA = _maxDepositForBucket(pid);
        if (assets > maxA) revert ERC4626ExceededMaxDeposit(receiver, assets, maxA);

        _updateReward(receiver);
        shares = previewDeposit(assets); // pre-increment state -> assets * SHARE_UNIT

        totalStakedAssets += assets;
        userPrincipal[receiver] += assets;
        partners[pid].tvl += assets;

        if (pullFromCaller) {
            IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        }
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
        emit Deposited(caller, receiver, assets, shares, pid);
    }

    /// @dev Resolves and (on first deposit) permanently fixes the receiver's bucket.
    function _resolveAttribution(address caller, address receiver, bytes32 referralPid, bool viaReferral)
        private
        returns (bytes32 pid)
    {
        bytes32 current = userPartner[receiver];
        if (current == bytes32(0)) {
            // First-ever attribution is write-once, so it must be authorized by the receiver
            // (or its operator) on BOTH the direct and referral paths. Without this symmetric
            // guard a third party could `deposit(1, victim)` to pin `victim` to PARTNER_DIRECT
            // and permanently block their later referral attribution (PartnerMismatch).
            if (caller != receiver && !isOperator[receiver][caller]) revert UnauthorizedAttribution();
            if (viaReferral) {
                if (!partners[referralPid].active) revert PartnerNotActive();
                pid = referralPid;
            } else {
                pid = PARTNER_DIRECT;
            }
            userPartner[receiver] = pid;
        } else {
            // Already attributed: a referral deposit must match; mixed buckets are forbidden.
            if (viaReferral && referralPid != current) revert PartnerMismatch();
            pid = current;
        }
    }

    // ---------------------------------------------------------------------
    // Async redeem (ERC-7540 inspired)
    // ---------------------------------------------------------------------

    /// @notice Requests redemption of `shares`; burns the aligned portion immediately and
    ///         starts the cooldown. Any sub-SHARE_UNIT remainder stays with the owner.
    /// @param shares Shares the owner wishes to redeem.
    /// @param controller Address entitled to later claim the request.
    /// @param owner Share owner (msg.sender or an approved operator).
    /// @return requestId Identifier of the created request.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert Unauthorized();
        // A zero controller can never satisfy _settleRedeem's `controller == msg.sender`,
        // so the burned principal would be permanently unclaimable.
        if (controller == address(0)) revert ZeroAddress();
        uint256 assets = shares / SHARE_UNIT; // floor
        if (assets == 0) revert ZeroAssets();
        uint256 burnShares = assets * SHARE_UNIT;

        _updateReward(owner);
        _burn(owner, burnShares); // reverts if owner balance < burnShares

        totalStakedAssets -= assets;
        totalPendingRedeemAssets += assets;
        userPrincipal[owner] -= assets;
        bytes32 pid = userPartner[owner];
        partners[pid].tvl -= assets;

        requestId = ++_nextRequestId;
        uint96 claimableAt = uint96(block.timestamp + cooldownPeriod);
        redeemRequests[requestId] =
            RedeemRequest({controller: controller, claimableAt: claimableAt, assets: assets, claimed: false});
        _userRequestIds[controller].push(requestId);

        emit RedeemRequested(owner, controller, requestId, burnShares, assets, claimableAt, pid);
    }

    /// @notice Claims a matured redeem request, returning principal as WXP.
    function claimRedeem(uint256 requestId, address receiver) external nonReentrant returns (uint256 assets) {
        assets = _settleRedeem(requestId);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, redeemRequests[requestId].controller, assets, assets * SHARE_UNIT);
        emit RedeemClaimed(msg.sender, receiver, requestId, assets, false);
    }

    /// @notice Claims a matured redeem request, returning principal as native XP.
    function claimRedeemNative(uint256 requestId, address receiver) external nonReentrant returns (uint256 assets) {
        assets = _settleRedeem(requestId);
        wxp.withdraw(assets);
        _sendNative(receiver, assets);
        emit Withdraw(msg.sender, receiver, redeemRequests[requestId].controller, assets, assets * SHARE_UNIT);
        emit RedeemClaimed(msg.sender, receiver, requestId, assets, true);
    }

    function _settleRedeem(uint256 requestId) private returns (uint256 assets) {
        RedeemRequest storage req = redeemRequests[requestId];
        if (req.controller != msg.sender) revert Unauthorized();
        if (req.claimed) revert AlreadyClaimed();
        if (block.timestamp < req.claimableAt) revert CooldownNotElapsed();
        req.claimed = true;
        assets = req.assets;
        totalPendingRedeemAssets -= assets;
    }

    /// @notice Sets or clears an operator approval for the caller (controller).
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ---------------------------------------------------------------------
    // Disabled synchronous exit (ERC-7540 async-only)
    // ---------------------------------------------------------------------

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert AsyncRedeemOnly();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert AsyncRedeemOnly();
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // ---------------------------------------------------------------------
    // Rewards
    // ---------------------------------------------------------------------

    /// @notice Streams `reward` WXP (already transferred in) to stakers over rewardsDuration.
    /// @dev Real-funding check: the vault's unbacked WXP balance must cover `reward`.
    function notifyRewardAmount(uint256 reward) external onlyRole(DISTRIBUTOR_ROLE) {
        uint256 backed = totalStakedAssets + totalPendingRedeemAssets + rewardReserves;
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance < backed + reward) revert RewardNotFunded();
        rewardReserves += reward;

        _updateReward(address(0));

        uint256 duration = rewardsDuration;
        uint256 leftover = block.timestamp < periodFinish ? (periodFinish - block.timestamp) * rewardRate : 0;
        uint256 total = reward + leftover;
        uint256 newRate = total / duration;
        rewardRate = newRate;
        unallocatedRewards += total - newRate * duration; // rounding dust

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        lastNotifyInterval = lastNotifiedAt != 0 ? block.timestamp - lastNotifiedAt : duration;
        lastNotifiedAt = block.timestamp;
        lastNotifiedReward = reward;

        emit RewardNotified(reward, newRate, periodFinish);
    }

    /// @notice Claims accrued rewards as WXP.
    function claimReward(address receiver) external nonReentrant returns (uint256 amount) {
        amount = _claimReward();
        if (amount > 0) IERC20(asset()).safeTransfer(receiver, amount);
        emit RewardClaimed(msg.sender, receiver, amount, false);
    }

    /// @notice Claims accrued rewards as native XP.
    function claimRewardNative(address receiver) external nonReentrant returns (uint256 amount) {
        amount = _claimReward();
        if (amount > 0) {
            wxp.withdraw(amount);
            _sendNative(receiver, amount);
        }
        emit RewardClaimed(msg.sender, receiver, amount, true);
    }

    function _claimReward() private returns (uint256 amount) {
        _updateReward(msg.sender);
        amount = rewards[msg.sender];
        if (amount > 0) {
            rewards[msg.sender] = 0;
            rewardReserves -= amount;
            totalRewardsDistributed += amount;
        }
    }

    /// @notice Recovers unallocated (stranded/dust) rewards back to the distributor.
    function sweepUnallocatedRewards() external onlyRole(PARAM_ADMIN_ROLE) nonReentrant {
        if (distributor == address(0)) revert DistributorNotSet();
        _updateReward(address(0));
        uint256 amount = unallocatedRewards;
        if (amount == 0) return;
        unallocatedRewards = 0;
        rewardReserves -= amount;
        wxp.withdraw(amount);
        (bool ok,) = distributor.call{value: amount}(abi.encodeWithSignature("receiveSweep()"));
        if (!ok) revert NativeTransferFailed();
        emit UnallocatedRewardsSwept(amount);
    }

    function _updateReward(address account) private {
        (uint256 rpt, uint256 newUnalloc) = _rewardPerTokenAndUnallocated();
        rewardPerTokenStored = rpt;
        if (newUnalloc > 0) unallocatedRewards += newUnalloc;
        lastUpdateTime = _lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = _earned(account, rpt);
            userRewardPerTokenPaid[account] = rpt;
        }
    }

    function _rewardPerTokenAndUnallocated() private view returns (uint256 rpt, uint256 newUnalloc) {
        uint256 applicable = _lastTimeRewardApplicable();
        if (applicable <= lastUpdateTime) return (rewardPerTokenStored, 0);
        uint256 delta = applicable - lastUpdateTime;
        uint256 ts = totalSupply();
        if (ts == 0) {
            return (rewardPerTokenStored, delta * rewardRate);
        }
        return (rewardPerTokenStored + (delta * rewardRate * PRECISION) / ts, 0);
    }

    function _earned(address account, uint256 rpt) private view returns (uint256) {
        return (balanceOf(account) * (rpt - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    function _lastTimeRewardApplicable() private view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Current reward-per-token accumulator.
    function rewardPerToken() public view returns (uint256 rpt) {
        (rpt,) = _rewardPerTokenAndUnallocated();
    }

    /// @notice Rewards accrued to `account` and not yet claimed.
    function earned(address account) public view returns (uint256) {
        (uint256 rpt,) = _rewardPerTokenAndUnallocated();
        return _earned(account, rpt);
    }

    // ---------------------------------------------------------------------
    // Governance / partner management
    // ---------------------------------------------------------------------

    function setStakeCap(uint256 newCap) external onlyRole(PARAM_ADMIN_ROLE) {
        emit StakeCapUpdated(stakeCap, newCap);
        stakeCap = newCap;
    }

    function setCooldownPeriod(uint256 newPeriod) external onlyRole(PARAM_ADMIN_ROLE) {
        if (newPeriod > maxCooldown) revert InvalidConfig();
        emit CooldownPeriodUpdated(cooldownPeriod, newPeriod);
        cooldownPeriod = newPeriod;
    }

    /// @notice Updates the reward streaming window; applied from the next notify.
    function setRewardsDuration(uint256 newDuration) external onlyRole(PARAM_ADMIN_ROLE) {
        if (newDuration < minRewardsDuration || newDuration > maxRewardsDuration) revert InvalidConfig();
        emit RewardsDurationUpdated(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    /// @notice Sets the RewardDistributor (sweep recipient); grant DISTRIBUTOR_ROLE separately.
    function setDistributor(address newDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit DistributorUpdated(distributor, newDistributor);
        distributor = newDistributor;
    }

    function registerPartner(bytes32 partnerId, uint256 subCap) external onlyRole(PARTNER_MANAGER_ROLE) {
        if (partnerId == bytes32(0) || partnerId == PARTNER_DIRECT) revert InvalidPartner();
        partners[partnerId].active = true;
        partners[partnerId].subCap = subCap;
        emit PartnerRegistered(partnerId, subCap);
    }

    function setPartnerCap(bytes32 partnerId, uint256 subCap) external onlyRole(PARTNER_MANAGER_ROLE) {
        if (!partners[partnerId].active) revert PartnerNotActive();
        emit PartnerCapUpdated(partnerId, partners[partnerId].subCap, subCap);
        partners[partnerId].subCap = subCap;
    }

    function setPartnerActive(bytes32 partnerId, bool active) external onlyRole(PARTNER_MANAGER_ROLE) {
        if (partnerId == bytes32(0) || partnerId == PARTNER_DIRECT) revert InvalidPartner();
        partners[partnerId].active = active;
        emit PartnerStatusUpdated(partnerId, active);
    }

    /// @notice Moves a user's entire principal from its current bucket to `newPartnerId`.
    /// @dev Dispute/mistake recovery. Preserves the single-bucket invariant.
    function reassignUserPartner(address user, bytes32 newPartnerId) external onlyRole(PARTNER_MANAGER_ROLE) {
        bytes32 old = userPartner[user];
        if (old == bytes32(0)) revert NotAttributed();
        if (newPartnerId == old) revert PartnerMismatch();
        if (newPartnerId != PARTNER_DIRECT && !partners[newPartnerId].active) revert PartnerNotActive();

        uint256 principal = userPrincipal[user];
        if (newPartnerId != PARTNER_DIRECT) {
            uint256 sub = partners[newPartnerId].subCap;
            if (sub != 0 && partners[newPartnerId].tvl + principal > sub) revert PartnerCapExceeded();
        }
        partners[old].tvl -= principal;
        partners[newPartnerId].tvl += principal;
        userPartner[user] = newPartnerId;
        emit PartnerReassigned(user, old, newPartnerId, principal);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Recovers non-WXP ERC-20 tokens mistakenly sent to the vault.
    /// @dev The vault asset (WXP) is disallowed so principal and reward reserves can never be
    ///      touched by governance (rug-proof). Native XP has no recovery path by design (§7.6).
    function recoverERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(wxp)) revert CannotRecoverAsset();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, to, amount);
    }

    // ---------------------------------------------------------------------
    // Views (aggregator / dashboard integration)
    // ---------------------------------------------------------------------

    /// @notice Effective APR at 1e18 scale (1e18 == 100%), based on the measured notify interval.
    function currentAPR() external view returns (uint256) {
        if (totalStakedAssets == 0 || lastNotifyInterval == 0) return 0;
        return (lastNotifiedReward * 365 days * PRECISION) / (lastNotifyInterval * totalStakedAssets);
    }

    function partnerTVL(bytes32 partnerId) external view returns (uint256) {
        return partners[partnerId].tvl;
    }

    function partnerInfo(bytes32 partnerId) external view returns (bool active, uint256 subCap, uint256 tvl) {
        Partner memory p = partners[partnerId];
        return (p.active, p.subCap, p.tvl);
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        bytes32 pid = userPartner[receiver];
        if (pid == bytes32(0)) pid = PARTNER_DIRECT;
        return _maxDepositForBucket(pid);
    }

    /// @inheritdoc ERC4626
    /// @dev Saturates instead of reverting: ERC-4626 requires maxMint to never revert, so an
    ///      extreme stakeCap that would overflow `maxA * SHARE_UNIT` returns type(uint256).max.
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxA = maxDeposit(receiver);
        if (maxA > type(uint256).max / SHARE_UNIT) return type(uint256).max;
        return maxA * SHARE_UNIT;
    }

    function _maxDepositForBucket(bytes32 pid) private view returns (uint256) {
        uint256 limit = stakeCap > totalStakedAssets ? stakeCap - totalStakedAssets : 0;
        if (pid != PARTNER_DIRECT) {
            uint256 sub = partners[pid].subCap;
            if (sub != 0) {
                uint256 tvl = partners[pid].tvl;
                uint256 bucket = sub > tvl ? sub - tvl : 0;
                if (bucket < limit) limit = bucket;
            }
        }
        return limit;
    }

    function totalPendingRedeem() external view returns (uint256) {
        return totalPendingRedeemAssets;
    }

    function rewardBalanceOf(address account) external view returns (uint256) {
        return earned(account);
    }

    function getUserRequestIds(address controller) external view returns (uint256[] memory) {
        return _userRequestIds[controller];
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        RedeemRequest memory r = redeemRequests[requestId];
        if (r.controller != controller || r.claimed || block.timestamp >= r.claimableAt) return 0;
        return r.assets * SHARE_UNIT;
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        RedeemRequest memory r = redeemRequests[requestId];
        if (r.controller != controller || r.claimed || block.timestamp < r.claimableAt) return 0;
        return r.assets * SHARE_UNIT;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @dev Shares are non-transferable; only mint (from==0) and burn (to==0) are allowed.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert TransfersDisabled();
        super._update(from, to, value);
    }

    /// @dev Resolve AccessControl / ERC-165 conflict.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

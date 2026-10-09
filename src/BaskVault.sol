// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FullMath} from "./libraries/FullMath.sol";
import {BoundedCall} from "./libraries/BoundedCall.sol";
import {PoolOracle} from "./libraries/PoolOracle.sol";
import {NewYorkTime} from "./libraries/NewYorkTime.sol";

/// @notice Basket's ERC-20 index vault share for Stock Tokens.
contract BaskVault {
    string public constant name = "Basket";
    string public constant symbol = "BASK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeRecipient;
    bool public genesisFinalized;
    bool public depositsPaused;
    uint256 public NAV_CAP = 1_000_000e18;
    uint256 private entered = 1;

    struct Settings {
        uint256 band;
        uint256 maxAge;
        uint256 noPoolAge;
        uint256 freshCount;
        uint256 freshHours;
        uint256 hoursFrom;
        uint256 hoursTo;
        uint256 dst;
        uint256 poolWindow;
        uint256 poolDeviation;
        uint256 feedGas;
        uint256 pauseGas;
        uint256 poolGas;
        uint256 balanceGas;
        uint256 payGas;
        uint256 maxAssets;
        uint256 directLimit;
    }
    Settings private cfg;

    struct Asset {
        address token;
        address feed;
        address pool;
        address quoteFeed;
        uint256 minLiquidity;
        uint256 centre;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        uint8 quoteDecimals;
        uint8 quoteFeedDecimals;
        bool open;
        bool retired;
        bool hasPause;
        bool baseIsToken0;
    }
    address[] private tokens;
    mapping(address => Asset) private assets;
    mapping(address => uint256) private indexPlusOne;
    mapping(address => address) public feedAsset;
    mapping(address => uint256) public managed;
    // The required gas bounds permit at most 350 assets (28m / (20k + 60k)).
    // Two words skip empty assets without reading their token or balance slots.
    uint256[2] private managedBits;
    uint256 private managedAssetCount;
    mapping(address => mapping(address => uint256)) public owed;
    mapping(address => uint256) public totalOwed;

    struct Deficit {
        uint256 amount;
        uint256 since;
    }
    mapping(address => Deficit) public deficits;

    enum Kind {
        List,
        Feed,
        Recentre,
        Reopen,
        Retire,
        Pool,
        Resync,
        Guardian,
        RaiseCap,
        FeeRecipient,
        Setting
    }
    enum Setting {
        Band,
        MaxAge,
        NoPoolAge,
        FreshCount,
        FreshHours,
        Hours,
        Dst,
        PoolWindow,
        PoolDeviation,
        FeedGas,
        PauseGas,
        PoolGas,
        BalanceGas,
        PayGas,
        MaxAssets,
        DirectLimit
    }

    /// @dev List: target=feed; Feed/Guardian/FeeRecipient: target=new address.
    /// Pool/List: pool, quoteFeed, value=minLiquidity. RaiseCap: value=USD18.
    /// Setting: setting, value; Hours also uses value2 for the end of the interval.
    struct Action {
        Kind kind;
        address token;
        address target;
        address pool;
        address quoteFeed;
        uint256 value;
        uint256 value2;
        Setting setting;
    }

    struct Proposal {
        Action action;
        uint256 createdAt;
        uint256 assetEpoch;
        uint256 closeEpoch;
        uint256 capEpoch;
        bool done;
    }
    uint256 public proposalCount;
    mapping(uint256 => Proposal) private proposals;
    mapping(address => uint256) private assetEpoch;
    mapping(address => uint256) private closeEpoch;
    uint256 private capEpoch;

    enum Reason {
        None,
        Genesis,
        Paused,
        Hours,
        Unlisted,
        Closed,
        Duplicate,
        BalanceUnreadable,
        Short,
        Feed,
        Band,
        OraclePaused,
        Pool,
        NoPoolAge,
        Freshness
    }

    struct AssetView {
        Asset config;
        uint256 answer;
        uint256 updatedAt;
        uint256 poolPrice;
        uint256 managedBalance;
        uint256 shortfall;
        uint256 owedBalance;
        bool balanceReadable;
        Reason reason;
    }

    error Unauthorized();
    error Reentrant();
    error InvalidAddress();
    error InvalidInput();
    error InvalidSetting();
    error InvalidAsset();
    error InvalidFeed();
    error InvalidPool();
    error InvalidProposal();
    error Timelock();
    error DepositUnavailable(Reason reason, address token);
    error BalanceUnreadable(address token);
    error PaymentFailed(address token);
    error Slippage();
    error Deadline();
    error CapExceeded();
    error ZeroNAV();
    error InsufficientBalance();
    error InsufficientAllowance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed account, address indexed spender, uint256 value);
    event OwnershipStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event GuardianChanged(address indexed guardian);
    event FeeRecipientChanged(address indexed recipient);
    event GenesisFinalized();
    event AssetListed(address indexed token, address indexed feed);
    event AssetClosed(address indexed token);
    event AssetRemoved(address indexed token);
    event AssetChanged(address indexed token, Kind indexed kind);
    event DepositsPaused(bool paused);
    event CapChanged(uint256 cap);
    event SettingChanged(Setting indexed setting, uint256 value, uint256 value2);
    event Proposed(uint256 indexed id, Action action, uint256 executableAt, uint256 expiresAt);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);
    event Deposit(address indexed caller, address indexed receiver, uint256 value, uint256 shares, uint256 fee);
    event Redeem(
        address indexed caller, address indexed receiver, uint256 shares, uint256 net, uint256 fee, uint256[] amounts
    );
    event Paid(address indexed token, address indexed to, uint256 amount);
    event Claimed(address indexed caller, address indexed to, address indexed token, uint256 amount);
    event DeficitFlagged(address indexed token, uint256 amount, uint256 since);
    event LossRecognized(address indexed token, uint256 amount);
    event Resynced(address indexed token, uint256 amount);

    constructor(address owner_, address guardian_) {
        if (owner_ == address(0) || guardian_ == address(0) || owner_ == guardian_) revert InvalidAddress();
        owner = owner_;
        guardian = guardian_;
        cfg = Settings(
            4,
            80 hours,
            26 hours,
            1,
            1,
            72000,
            504000,
            0,
            1800,
            300,
            100_000,
            100_000,
            150_000,
            50_000,
            250_000,
            250,
            50
        );
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
    }

    modifier nonReentrant() {
        if (entered != 1) revert Reentrant();
        entered = 2;
        _;
        entered = 1;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyRole() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    function approve(address spender, uint256 amount) external nonReentrant returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidAddress();
        _update(from, to, amount);
    }

    function _mint(address to, uint256 amount) private {
        if (to == address(0)) revert InvalidAddress();
        _update(address(0), to, amount);
    }

    function _update(address from, address to, uint256 amount) private {
        if (from == address(0)) {
            totalSupply += amount;
        } else {
            if (balanceOf[from] < amount) revert InsufficientBalance();
            balanceOf[from] -= amount;
        }
        if (to == address(0)) totalSupply -= amount;
        else balanceOf[to] += amount;
        // Compute the standard topic in scratch memory. This keeps solc's shared
        // constant data out of the runtime tail (the deployment opcode scanner
        // also scans that data). Event ABI and topic remain standard ERC-20.
        assembly ("memory-safe") {
            mstore(0, "Transfer(address,address,uint256")
            mstore(32, shl(248, 0x29))
            let topic := keccak256(0, 33)
            mstore(0, amount)
            log3(0, 32, topic, from, to)
        }
    }

    function transferOwnership(address next) external onlyOwner nonReentrant {
        if (next == address(0) || next == guardian) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipStarted(owner, next);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner || msg.sender == guardian) revert Unauthorized();
        address old = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    function pauseDeposits() external onlyRole nonReentrant {
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    function unpauseDeposits() external onlyOwner nonReentrant {
        depositsPaused = false;
        emit DepositsPaused(false);
    }

    function close(address token) external onlyRole nonReentrant {
        _asset(token);
        assets[token].open = false;
        ++closeEpoch[token];
        emit AssetClosed(token);
    }

    function lowerNAVCap(uint256 cap) external onlyOwner nonReentrant {
        if (cap >= NAV_CAP) revert InvalidInput();
        NAV_CAP = cap;
        ++capEpoch;
        emit CapChanged(cap);
    }

    function listGenesis(address token, address feed, address pool, address quoteFeed, uint256 minLiquidity)
        external
        onlyOwner
        nonReentrant
    {
        if (genesisFinalized) revert InvalidInput();
        _list(token, feed, pool, quoteFeed, minLiquidity);
    }

    function finalizeGenesis() external onlyOwner nonReentrant {
        if (genesisFinalized || tokens.length < 3) revert InvalidInput();
        genesisFinalized = true;
        emit GenesisFinalized();
    }

    function removeRetired(address token) external nonReentrant {
        Asset storage a = _asset(token);
        if (!a.retired || managed[token] != 0 || totalOwed[token] != 0) revert InvalidAsset();
        uint256 i = indexPlusOne[token] - 1;
        address last = tokens[tokens.length - 1];
        if (managed[last] != 0) {
            _markManaged(tokens.length - 1, false);
            _markManaged(i, true);
        }
        tokens[i] = last;
        indexPlusOne[last] = i + 1;
        tokens.pop();
        delete indexPlusOne[token];
        delete assets[token];
        delete deficits[token];
        ++assetEpoch[token];
        emit AssetRemoved(token);
    }

    function propose(Action calldata action) external onlyOwner nonReentrant returns (uint256 id) {
        _validate(action);
        id = ++proposalCount;
        proposals[id] =
            Proposal(action, block.timestamp, assetEpoch[action.token], closeEpoch[action.token], capEpoch, false);
        emit Proposed(id, action, block.timestamp + 2 days, block.timestamp + 9 days);
    }

    function cancel(uint256 id) external onlyRole nonReentrant {
        Proposal storage p = proposals[id];
        if (!_pending(id) || (msg.sender == guardian && p.action.kind == Kind.Guardian)) revert InvalidProposal();
        p.done = true;
        emit ProposalCancelled(id);
    }

    function execute(uint256 id) external onlyOwner nonReentrant {
        if (!_pending(id)) revert InvalidProposal();
        Proposal storage p = proposals[id];
        if (block.timestamp < p.createdAt + 2 days) revert Timelock();
        Action memory a = p.action;
        _validate(a);
        p.done = true;
        if (a.kind == Kind.List) {
            _list(a.token, a.target, a.pool, a.quoteFeed, a.value);
        } else if (a.kind == Kind.Guardian) {
            guardian = a.target;
            emit GuardianChanged(a.target);
        } else if (a.kind == Kind.RaiseCap) {
            NAV_CAP = a.value;
            emit CapChanged(a.value);
        } else if (a.kind == Kind.FeeRecipient) {
            feeRecipient = a.target;
            emit FeeRecipientChanged(a.target);
        } else if (a.kind == Kind.Setting) {
            cfg = _changedSettings(a.setting, a.value, a.value2);
            emit SettingChanged(a.setting, a.value, a.value2);
        } else {
            Asset storage item = assets[a.token];
            if (a.kind == Kind.Feed) {
                delete feedAsset[item.feed];
                item.feed = a.target;
                feedAsset[a.target] = a.token;
                item.feedDecimals = _decimals(a.target);
                item.centre = _listingAnswer(a.target);
            } else if (a.kind == Kind.Recentre) {
                item.centre = _listingAnswer(item.feed);
            } else if (a.kind == Kind.Reopen) {
                item.open = true;
            } else if (a.kind == Kind.Retire) {
                item.retired = true;
                delete feedAsset[item.feed];
                ++assetEpoch[a.token];
            } else if (a.kind == Kind.Pool) {
                _setPool(item, a.pool, a.quoteFeed, a.value);
            } else if (a.kind == Kind.Resync) {
                (bool ok, uint256 available) = _available(a.token);
                if (!ok) revert BalanceUnreadable(a.token);
                uint256 extra = available > managed[a.token] ? available - managed[a.token] : 0;
                _setManaged(a.token, managed[a.token] + extra);
                emit Resynced(a.token, extra);
            }
            emit AssetChanged(a.token, a.kind);
        }
        emit ProposalExecuted(id);
    }

    function _validate(Action memory a) private view {
        if (a.kind == Kind.List) {
            _checkListing(a.token, a.target);
            _poolConfig(a.token, a.pool, a.quoteFeed, a.value);
        } else if (a.kind == Kind.Guardian) {
            if (a.target == address(0) || a.target == owner) revert InvalidAddress();
        } else if (a.kind == Kind.RaiseCap) {
            if (a.value <= NAV_CAP || a.value > 10_000_000_000e18) revert InvalidInput();
        } else if (a.kind == Kind.FeeRecipient) {
            if (a.target == address(0) || a.target == address(this)) revert InvalidAddress();
        } else if (a.kind == Kind.Setting) {
            _changedSettings(a.setting, a.value, a.value2);
        } else {
            Asset storage item = _asset(a.token);
            if (item.retired && a.kind != Kind.Resync) revert InvalidAsset();
            if (a.kind == Kind.Feed) {
                _checkFeed(a.token, a.target);
            } else if (a.kind == Kind.Recentre) {
                _listingAnswer(item.feed);
            } else if (a.kind == Kind.Retire && item.open) {
                revert InvalidAsset();
            } else if (a.kind == Kind.Pool) {
                _poolConfig(a.token, a.pool, a.quoteFeed, a.value);
            }
        }
    }

    function _pending(uint256 id) private view returns (bool) {
        if (id == 0 || id > proposalCount) return false;
        Proposal storage p = proposals[id];
        if (p.done || block.timestamp >= p.createdAt + 9 days) return false;
        Kind k = p.action.kind;
        if (uint256(k) <= uint256(Kind.Resync) && p.assetEpoch != assetEpoch[p.action.token]) return false;
        if (k == Kind.Reopen && p.closeEpoch != closeEpoch[p.action.token]) return false;
        if (k == Kind.RaiseCap && p.capEpoch != capEpoch) return false;
        return true;
    }

    function _asset(address token) private view returns (Asset storage a) {
        if (indexPlusOne[token] == 0) revert InvalidAsset();
        a = assets[token];
    }

    function _checkFeed(address token, address feed) private view {
        if (feedAsset[feed] != address(0) && feedAsset[feed] != token) revert InvalidFeed();
        _decimals(feed);
        _listingAnswer(feed);
    }

    function _checkListing(address token, address feed) private view {
        if (indexPlusOne[token] != 0 || tokens.length >= cfg.maxAssets) revert InvalidAsset();
        _decimals(token);
        _checkFeed(token, feed);
    }

    function _list(address token, address feed, address pool, address quoteFeed, uint256 minLiquidity) private {
        _checkListing(token, feed);
        Asset storage a = assets[token];
        a.token = token;
        a.feed = feed;
        a.tokenDecimals = _decimals(token);
        a.feedDecimals = _decimals(feed);
        a.centre = _listingAnswer(feed);
        a.open = true;
        (bool ok, uint256 paused) = BoundedCall.word(token, abi.encodeWithSignature("oraclePaused()"), cfg.pauseGas);
        a.hasPause = ok && paused <= 1;
        _setPool(a, pool, quoteFeed, minLiquidity);
        feedAsset[feed] = token;
        tokens.push(token);
        indexPlusOne[token] = tokens.length;
        ++assetEpoch[token];
        emit AssetListed(token, feed);
    }

    function _poolConfig(address token, address pool, address quoteFeed, uint256 minLiquidity)
        private
        view
        returns (uint8 qd, uint8 qfd, bool baseIsToken0)
    {
        if (pool == address(0)) {
            if (quoteFeed != address(0) || minLiquidity != 0) revert InvalidPool();
            return (0, 0, false);
        }
        (bool ok0, uint256 t0) = BoundedCall.word(pool, abi.encodeWithSignature("token0()"), cfg.poolGas);
        (bool ok1, uint256 t1) = BoundedCall.word(pool, abi.encodeWithSignature("token1()"), cfg.poolGas);
        if (
            !ok0 || !ok1 || t0 > type(uint160).max || t1 > type(uint160).max || t0 == t1
                || (address(uint160(t0)) != token && address(uint160(t1)) != token)
        ) revert InvalidPool();
        baseIsToken0 = address(uint160(t0)) == token;
        qd = _decimals(address(uint160(baseIsToken0 ? t1 : t0)));
        qfd = _decimals(quoteFeed);
    }

    function _setPool(Asset storage a, address pool, address quoteFeed, uint256 minLiquidity) private {
        (a.quoteDecimals, a.quoteFeedDecimals, a.baseIsToken0) = _poolConfig(a.token, pool, quoteFeed, minLiquidity);
        a.pool = pool;
        a.quoteFeed = quoteFeed;
        a.minLiquidity = minLiquidity;
    }

    function _decimals(address target) private view returns (uint8) {
        (bool ok, uint256 d) = BoundedCall.word(target, abi.encodeWithSignature("decimals()"), cfg.feedGas);
        if (!ok || d > 18) revert InvalidFeed();
        return uint8(d);
    }

    function _listingAnswer(address feed) private view returns (uint256 answer) {
        (bool ok, uint256 v,) = _feed(feed);
        if (!ok) revert InvalidFeed();
        return v;
    }

    function _changedSettings(Setting s, uint256 v, uint256 v2) private view returns (Settings memory c) {
        c = cfg;
        if (s == Setting.Band) {
            _bound(v, 2, 100);
            c.band = v;
        } else if (s == Setting.MaxAge) {
            _bound(v, 1 hours, 30 days);
            c.maxAge = v;
        } else if (s == Setting.NoPoolAge) {
            _bound(v, 1 hours, 30 days);
            c.noPoolAge = v;
        } else if (s == Setting.FreshCount) {
            _bound(v, 0, 10);
            c.freshCount = v;
        } else if (s == Setting.FreshHours) {
            _bound(v, 1, 48);
            c.freshHours = v;
        } else if (s == Setting.Hours) {
            if ((v != 0 || v2 != 0) && (v >= v2 || v2 > 1 weeks)) revert InvalidSetting();
            c.hoursFrom = v;
            c.hoursTo = v2;
        } else if (s == Setting.Dst) {
            _bound(v, 0, 2);
            c.dst = v;
        } else if (s == Setting.PoolWindow) {
            _bound(v, 300, 86400);
            c.poolWindow = v;
        } else if (s == Setting.PoolDeviation) {
            _bound(v, 50, 2000);
            c.poolDeviation = v;
        } else if (s == Setting.MaxAssets) {
            c.maxAssets = v;
        } else if (s == Setting.DirectLimit) {
            c.directLimit = v;
        } else {
            _bound(v, 20_000, 500_000);
            if (s == Setting.FeedGas) c.feedGas = v;
            else if (s == Setting.PauseGas) c.pauseGas = v;
            else if (s == Setting.PoolGas) c.poolGas = v;
            else if (s == Setting.BalanceGas) c.balanceGas = v;
            else c.payGas = v;
        }
        // Division makes extreme input values fail with the same custom error, without overflow.
        if (
            c.maxAssets < tokens.length || c.maxAssets > 28_000_000 / (c.balanceGas + 60_000)
                || c.directLimit > 28_000_000 / (c.balanceGas + c.payGas + 70_000)
        ) revert InvalidSetting();
    }

    function _bound(uint256 v, uint256 lo, uint256 hi) private pure {
        if (v < lo || v > hi) revert InvalidSetting();
    }

    function deposit(
        address[] calldata inputTokens,
        uint256[] calldata amounts,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 shares) {
        if (block.timestamp > deadline) revert Deadline();
        if (receiver == address(this) || receiver == address(0)) revert InvalidAddress();
        if (inputTokens.length != amounts.length) revert InvalidInput();
        (Reason reason, address fault, uint256 nav, uint256[] memory answers) = _depositState(inputTokens);
        if (reason != Reason.None) revert DepositUnavailable(reason, fault);
        uint256 value;
        for (uint256 i; i < inputTokens.length; ++i) {
            if (amounts[i] == 0) revert InvalidInput();
            Asset storage a = assets[inputTokens[i]];
            value += _value(amounts[i], answers[indexPlusOne[a.token] - 1], a.tokenDecimals, a.feedDecimals);
        }
        uint256 fee;
        (shares, fee) = _depositShares(value, nav);
        if (shares == 0 || shares < minSharesOut) revert Slippage();
        if (nav > NAV_CAP || value > NAV_CAP - nav) revert CapExceeded();
        for (uint256 i; i < inputTokens.length; ++i) {
            address token = inputTokens[i];
            uint256 beforeBalance = _balanceRequired(token, cfg.balanceGas);
            if (!BoundedCall.transfer(
                    token,
                    abi.encodeWithSignature(
                        "transferFrom(address,address,uint256)", msg.sender, address(this), amounts[i]
                    )
                )) {
                revert PaymentFailed(token);
            }
            uint256 afterBalance = _balanceRequired(token, cfg.balanceGas);
            if (afterBalance < beforeBalance || afterBalance - beforeBalance != amounts[i]) {
                revert PaymentFailed(token);
            }
            _setManaged(token, managed[token] + amounts[i]);
        }
        for (uint256 i; i < tokens.length; ++i) {
            if (!assets[tokens[i]].retired) delete deficits[tokens[i]];
        }
        if (totalSupply == 0) _mint(address(0xdEaD), 1e15);
        if (fee != 0) _mint(feeRecipient, fee);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, value, shares, fee);
    }

    function _depositShares(uint256 value, uint256 nav) private view returns (uint256 shares, uint256 fee) {
        uint256 supply = totalSupply;
        if (supply != 0 && nav == 0) revert ZeroNAV();
        uint256 gross = supply == 0 ? value : FullMath.mulDiv(value, supply, nav);
        fee = _fee(gross);
        shares = gross - fee;
        if (supply == 0) {
            if (shares <= 1e15) revert Slippage();
            shares -= 1e15;
        }
    }

    function _fee(uint256 amount) private view returns (uint256) {
        // ceil(amount * 50 / 10000), without multiplication overflow.
        return feeRecipient == address(0) ? 0 : amount / 200 + (amount % 200 == 0 ? 0 : 1);
    }

    function redeem(uint256 shares, address receiver, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert Deadline();
        if (receiver == address(0)) revert InvalidAddress();
        if (balanceOf[msg.sender] < shares) revert InsufficientBalance();
        uint256 supply = totalSupply;
        uint256 fee = _fee(shares);
        uint256 net = shares - fee;
        if (fee != 0) _transfer(msg.sender, feeRecipient, fee);
        _update(msg.sender, address(0), net);
        uint256 length = tokens.length;
        uint256 active = managedAssetCount;
        bool direct = active <= cfg.directLimit;
        bool allActive = active == length;
        uint256[2] memory bits;
        if (!allActive) bits = managedBits;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            if (!allActive && bits[i >> 8] & (uint256(1) << (i & 255)) == 0) {
                if (i < minAmountsOut.length && minAmountsOut[i] != 0) revert Slippage();
                continue;
            }
            address token = tokens[i];
            uint256 m = managed[token];
            uint256 leg;
            if (m != 0 && net != 0) {
                (bool ok, uint256 available) = _available(token);
                if (!ok) available = m;
                leg = FullMath.mulDiv(available < m ? available : m, net, supply);
            }
            if (i < minAmountsOut.length && leg < minAmountsOut[i]) revert Slippage();
            amounts[i] = leg;
            if (leg == 0) continue;
            managed[token] = m - leg;
            if (m == leg) {
                --managedAssetCount;
                _markManaged(i, false);
            }
            if (!direct || !_tryPay(token, receiver, leg, cfg.payGas)) {
                owed[receiver][token] += leg;
                totalOwed[token] += leg;
            }
        }
        // Paid events identify direct legs; every other nonzero leg is queued.
        emit Redeem(msg.sender, receiver, shares, net, fee, amounts);
    }

    /// @dev The outer entry point owns the reentrancy lock. A failed self-call rolls
    /// back even a token that mutates balances and subsequently reports failure.
    function pay(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        uint256 beforeBalance = _balanceRequired(token, gasleft());
        if (!BoundedCall.transfer(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount))) {
            revert PaymentFailed(token);
        }
        uint256 afterBalance = _balanceRequired(token, gasleft());
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert PaymentFailed(token);
        emit Paid(token, to, amount);
    }

    function _tryPay(address token, address to, uint256 amount, uint256 gasLimit) private returns (bool ok) {
        bytes memory data = abi.encodeCall(this.pay, (token, to, amount));
        // No return data is copied, including on failure.
        assembly ("memory-safe") { ok := call(gasLimit, address(), 0, add(data, 32), mload(data), 0, 0) }
    }

    function claim(address[] calldata claimTokens, address to) external nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        for (uint256 i; i < claimTokens.length; ++i) {
            address token = claimTokens[i];
            uint256 amount = owed[msg.sender][token];
            if (amount != 0) {
                uint256 bal = _balanceRequired(token, gasleft());
                if (amount > bal) amount = bal;
                if (amount != 0) {
                    owed[msg.sender][token] -= amount;
                    totalOwed[token] -= amount;
                    if (!_tryPay(token, to, amount, gasleft())) revert PaymentFailed(token);
                }
            }
            emit Claimed(msg.sender, to, token, amount);
        }
    }

    function _balance(address token) private view returns (bool ok, uint256 bal) {
        return _balanceAt(token, cfg.balanceGas);
    }

    function _balanceAt(address token, uint256 gasLimit) private view returns (bool ok, uint256 bal) {
        // Fixed input and output fit in scratch memory; no per-asset allocation.
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x70a08231))
            mstore(4, address())
            ok := staticcall(gasLimit, token, 0, 36, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            bal := mload(0)
        }
    }

    function _balanceRequired(address token, uint256 gasLimit) private view returns (uint256 bal) {
        bool ok;
        (ok, bal) = _balanceAt(token, gasLimit);
        if (!ok) revert BalanceUnreadable(token);
    }

    function _available(address token) private view returns (bool ok, uint256 available) {
        (ok, available) = _balance(token);
        if (!ok) return (false, 0);
        uint256 debt = totalOwed[token];
        available = available > debt ? available - debt : 0;
    }

    function _markManaged(uint256 index, bool active) private {
        uint256 bit = uint256(1) << (index & 255);
        if (active) managedBits[index >> 8] |= bit;
        else managedBits[index >> 8] &= ~bit;
    }

    function _setManaged(address token, uint256 amount) private {
        uint256 previous = managed[token];
        if (previous == 0 && amount != 0) {
            ++managedAssetCount;
            _markManaged(indexPlusOne[token] - 1, true);
        } else if (previous != 0 && amount == 0) {
            --managedAssetCount;
            _markManaged(indexPlusOne[token] - 1, false);
        }
        managed[token] = amount;
    }

    function flagDeficit(address token) external nonReentrant {
        _asset(token);
        uint256 shortfall = _shortfall(token);
        Deficit storage d = deficits[token];
        if (shortfall == 0) {
            delete deficits[token];
        } else if (shortfall > d.amount) {
            d.amount = shortfall;
            d.since = block.timestamp;
        }
        emit DeficitFlagged(token, deficits[token].amount, deficits[token].since);
    }

    function recognizeLoss(address token) external nonReentrant {
        _asset(token);
        Deficit memory d = deficits[token];
        if (d.amount == 0 || block.timestamp < d.since + 7 days) revert Timelock();
        uint256 loss = _shortfall(token);
        if (loss > d.amount) loss = d.amount;
        _setManaged(token, managed[token] - loss);
        delete deficits[token];
        emit LossRecognized(token, loss);
    }

    function _shortfall(address token) private view returns (uint256) {
        (bool ok, uint256 available) = _available(token);
        if (!ok) revert BalanceUnreadable(token);
        uint256 m = managed[token];
        return m > available ? m - available : 0;
    }

    function _feed(address feed) private view returns (bool ok, uint256 answer, uint256 updatedAt) {
        bytes memory data;
        (ok, data) = BoundedCall.read(feed, abi.encodeWithSignature("latestRoundData()"), cfg.feedGas, 160);
        int256 signedAnswer;
        assembly ("memory-safe") {
            signedAnswer := mload(add(data, 64))
            updatedAt := mload(add(data, 128))
        }
        if (signedAnswer > 0) answer = uint256(signedAnswer);
        ok = ok && signedAnswer > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= cfg.maxAge;
    }

    function _price(Asset storage a)
        private
        view
        returns (Reason reason, uint256 answer, uint256 updatedAt, uint256 poolPrice)
    {
        bool ok;
        (ok, answer, updatedAt) = _feed(a.feed);
        if (!ok) return (Reason.Feed, answer, updatedAt, 0);
        // (answer-1)/band >= centre is the overflow-free test for answer > centre*band.
        if (answer < a.centre / cfg.band || (answer - 1) / cfg.band >= a.centre) {
            return (Reason.Band, answer, updatedAt, 0);
        }
        if (a.hasPause) {
            uint256 paused;
            (ok, paused) = BoundedCall.word(a.token, abi.encodeWithSignature("oraclePaused()"), cfg.pauseGas);
            if (!ok || paused != 0) return (Reason.OraclePaused, answer, updatedAt, 0);
        }
        if (a.pool == address(0)) {
            if (block.timestamp - updatedAt > cfg.noPoolAge) reason = Reason.NoPoolAge;
        } else {
            int24 tick;
            uint128 liq;
            (ok, tick, liq) = PoolOracle.consult(a.pool, uint32(cfg.poolWindow), cfg.poolGas);
            if (!ok || liq < a.minLiquidity) return (Reason.Pool, answer, updatedAt, 0);
            uint256 quoteAnswer;
            (ok, quoteAnswer,) = _feed(a.quoteFeed);
            if (!ok) return (Reason.Pool, answer, updatedAt, 0);
            uint256 quoteAmount = PoolOracle.quote(tick, uint128(10 ** a.tokenDecimals), a.baseIsToken0);
            poolPrice = _value(quoteAmount, quoteAnswer, a.quoteDecimals, a.quoteFeedDecimals);
            uint256 feedPrice = _value(10 ** a.tokenDecimals, answer, a.tokenDecimals, a.feedDecimals);
            uint256 diff = poolPrice > feedPrice ? poolPrice - feedPrice : feedPrice - poolPrice;
            if (diff > FullMath.mulDiv(feedPrice, cfg.poolDeviation, 10_000)) reason = Reason.Pool;
        }
    }

    function _value(uint256 amount, uint256 answer, uint8 td, uint8 fd) private pure returns (uint256) {
        uint256 exponent = uint256(td) + fd;
        if (exponent >= 18) return FullMath.mulDiv(amount, answer, 10 ** (exponent - 18));
        return FullMath.mulDiv(amount, answer, 1) * 10 ** (18 - exponent);
    }

    function insideHours() public view returns (bool) {
        if (cfg.hoursFrom == 0 && cfg.hoursTo == 0) return true;
        uint256 second = NewYorkTime.weekSecond(block.timestamp, cfg.dst);
        return second >= cfg.hoursFrom && second < cfg.hoursTo;
    }

    function _depositState(address[] memory inputTokens)
        private
        view
        returns (Reason reason, address fault, uint256 nav, uint256[] memory answers)
    {
        answers = new uint256[](tokens.length);
        if (!genesisFinalized) return (Reason.Genesis, address(0), 0, answers);
        if (depositsPaused) return (Reason.Paused, address(0), 0, answers);
        if (!insideHours()) return (Reason.Hours, address(0), 0, answers);
        bool[] memory selected = new bool[](tokens.length);
        for (uint256 i; i < inputTokens.length; ++i) {
            address token = inputTokens[i];
            uint256 index = indexPlusOne[token];
            if (index == 0) return (Reason.Unlisted, token, 0, answers);
            if (!assets[token].open || assets[token].retired) return (Reason.Closed, token, 0, answers);
            if (selected[index - 1]) return (Reason.Duplicate, token, 0, answers);
            selected[index - 1] = true;
        }
        uint256 fresh;
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            Asset storage a = assets[token];
            if (a.retired) continue;
            (bool ok, uint256 bal) = _balance(token);
            if (!ok) return (Reason.BalanceUnreadable, token, 0, answers);
            uint256 debt = totalOwed[token];
            uint256 available = bal > debt ? bal - debt : 0;
            if (available < managed[token] || (selected[i] && bal < debt)) return (Reason.Short, token, 0, answers);
            uint256 answer;
            uint256 updatedAt;
            if (selected[i] || managed[token] != 0) {
                (reason, answer, updatedAt,) = _price(a);
                if (reason != Reason.None) return (reason, token, 0, answers);
                answers[i] = answer;
                nav += _value(managed[token], answer, a.tokenDecimals, a.feedDecimals);
                ok = true;
            } else {
                (ok, answer, updatedAt) = _feed(a.feed);
            }
            if (ok && block.timestamp - updatedAt <= cfg.freshHours * 1 hours) ++fresh;
        }
        if (fresh < cfg.freshCount) return (Reason.Freshness, address(0), nav, answers);
        return (Reason.None, address(0), nav, answers);
    }

    function settings() external view returns (Settings memory) {
        return cfg;
    }

    function assetCount() external view returns (uint256) {
        return tokens.length;
    }

    function assetTokens() external view returns (address[] memory) {
        return tokens;
    }

    function asset(address token) external view returns (Asset memory) {
        return _asset(token);
    }

    function allAssets() external view returns (AssetView[] memory result) {
        result = new AssetView[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            AssetView memory v;
            v.config = assets[token];
            (v.reason, v.answer, v.updatedAt, v.poolPrice) = _price(assets[token]);
            v.managedBalance = managed[token];
            v.owedBalance = totalOwed[token];
            uint256 available;
            (v.balanceReadable, available) = _available(token);
            if (v.balanceReadable && v.managedBalance > available) v.shortfall = v.managedBalance - available;
            result[i] = v;
        }
    }

    function depositStatus(address[] calldata inputTokens) external view returns (Reason reason, address fault) {
        (reason, fault,,) = _depositState(inputTokens);
    }

    function previewDeposit(address[] calldata inputTokens, uint256[] calldata amounts)
        external
        view
        returns (uint256 shares, uint256 fee, uint256 value, uint256 nav)
    {
        if (inputTokens.length != amounts.length) revert InvalidInput();
        Reason reason;
        address fault;
        uint256[] memory answers;
        (reason, fault, nav, answers) = _depositState(inputTokens);
        if (reason != Reason.None) revert DepositUnavailable(reason, fault);
        for (uint256 i; i < inputTokens.length; ++i) {
            if (amounts[i] == 0) revert InvalidInput();
            Asset storage a = assets[inputTokens[i]];
            value += _value(amounts[i], answers[indexPlusOne[a.token] - 1], a.tokenDecimals, a.feedDecimals);
        }
        (shares, fee) = _depositShares(value, nav);
        if (shares == 0) revert Slippage();
        if (nav > NAV_CAP || value > NAV_CAP - nav) revert CapExceeded();
    }

    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts, uint256 fee, bool direct) {
        if (shares > totalSupply) revert InsufficientBalance();
        fee = _fee(shares);
        uint256 net = shares - fee;
        amounts = new uint256[](tokens.length);
        uint256 active;
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 m = managed[token];
            if (m == 0) continue;
            ++active;
            if (net == 0) continue;
            (bool ok, uint256 available) = _available(token);
            if (!ok) available = m;
            amounts[i] = FullMath.mulDiv(available < m ? available : m, net, totalSupply);
        }
        direct = active <= cfg.directLimit;
    }

    function proposal(uint256 id) external view returns (Proposal memory data, bool pending) {
        return (proposals[id], _pending(id));
    }

    /// @notice IDs in a bounded inclusive range; pending includes proposals still waiting.
    function pendingProposals(uint256 first, uint256 last) external view returns (uint256[] memory ids) {
        if (first == 0) first = 1;
        if (last > proposalCount) last = proposalCount;
        if (last < first) return new uint256[](0);
        ids = new uint256[](last - first + 1);
        uint256 count;
        for (uint256 i = first; i <= last; ++i) {
            if (_pending(i)) ids[count++] = i;
        }
        assembly ("memory-safe") { mstore(ids, count) }
    }
}

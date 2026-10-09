// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockToken {
    uint8 public decimals;
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) public allowance;
    // 1 revert; 2 consume gas; 3 short output; 4 huge output.
    uint256 public balanceMode;
    // 1 revert/blocked; 2 consume gas; 3 false after moving; 4 no return;
    // 5 one-byte output; 6 wrong debit; 7 huge true output; 8 require > payGas.
    uint256 public transferMode;
    uint256 public pauseMode;
    bool public paused;
    bool public taxPull;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;

    error MockFailure();

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setBalanceMode(uint256 mode) external {
        balanceMode = mode;
    }

    function setTransferMode(uint256 mode) external {
        transferMode = mode;
    }

    function setPauseMode(uint256 mode) external {
        pauseMode = mode;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setTaxPull(bool value) external {
        taxPull = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function confiscate(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function rawBalance(address account) external view returns (uint256) {
        return balances[account];
    }

    function balanceOf(address account) external view returns (uint256 value) {
        uint256 mode = balanceMode;
        if (mode == 1) revert MockFailure();
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 1) }
        }
        if (mode == 6 && gasleft() < 75_000) revert MockFailure();
        value = balances[account];
        if (mode == 5) {
            assembly ("memory-safe") { for {} gt(gas(), 1500) {} {} }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, value)
                return(p, 65536)
            }
        }
    }

    function oraclePaused() external view returns (bool) {
        if (pauseMode == 1) revert MockFailure();
        if (pauseMode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (pauseMode == 3) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return paused;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += taxPull ? amount - 1 : amount;
        _callback();
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 mode = transferMode;
        if (mode == 1) revert MockFailure();
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 8 && gasleft() < 300_000) revert MockFailure();
        balances[msg.sender] -= mode == 6 ? amount - 1 : amount;
        balances[to] += amount;
        _callback();
        if (mode == 3) return false;
        if (mode == 4) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 5) {
            assembly ("memory-safe") { return(0, 1) }
        }
        if (mode == 7) {
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, 1)
                return(p, 65536)
            }
        }
        return true;
    }

    function _callback() private {
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
    }
}

contract MockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public mode;

    constructor(uint8 d, int256 v) {
        decimals = d;
        answer = v;
        updatedAt = block.timestamp;
    }

    function set(int256 v, uint256 at) external {
        answer = v;
        updatedAt = at;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == 1) revert();
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 32) }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockPool {
    address public token0;
    address public token1;
    int56 public tickDelta;
    uint160 public liquidityDelta;
    int56 public tickStart;
    uint160 public liquidityStart;
    uint256 public mode;
    uint32 public expectedWindow = 1800;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
        liquidityDelta = uint160((uint256(1800) << 128) / 1e12);
    }

    function set(int56 dt, uint160 ds) external {
        tickDelta = dt;
        liquidityDelta = ds;
    }

    function setStarts(int56 t, uint160 s) external {
        tickStart = t;
        liquidityStart = s;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function setWindow(uint32 w) external {
        expectedWindow = w;
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory t, uint160[] memory s) {
        if (mode == 1) revert();
        if (mode == 2) {
            assembly ("memory-safe") { invalid() }
        }
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 32) }
        }
        require(ago.length == 2 && ago[0] == expectedWindow && ago[1] == 0, "window");
        t = new int56[](2);
        s = new uint160[](2);
        t[0] = tickStart;
        s[0] = liquidityStart;
        unchecked {
            t[1] = tickStart + tickDelta;
            s[1] = liquidityStart + liquidityDelta;
        }
    }
}

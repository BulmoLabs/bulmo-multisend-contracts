// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Standard ERC-20 with public mint (6 decimals like USDC).
contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Takes a percentage on every transfer (fee-on-transfer / tax token).
contract TaxToken is ERC20 {
    uint256 public immutable taxBps;
    address public constant SINK = address(0xdead);

    constructor(uint256 bps) ERC20("Tax", "TAX") {
        taxBps = bps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || to == SINK) return super._update(from, to, value);
        uint256 tax = (value * taxBps) / 10_000;
        super._update(from, SINK, tax);
        super._update(from, to, value - tax);
    }
}

/// USDT-style: transfer/transferFrom return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Returns false instead of reverting when a transfer fails.
contract FalseReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount || balanceOf[from] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IMultisend {
    function sendToken(address token, address[] calldata r, uint256[] calldata a) external payable returns (uint256);
    function sendNative(address[] calldata r, uint256[] calldata a) external payable returns (uint256);
    function withdrawFees(address payable to) external;
}

/// Malicious token: tries to re-enter the multisend during transferFrom.
contract ReentrantToken is ERC20 {
    IMultisend public target;
    bool public attacked;

    constructor() ERC20("Evil", "EVIL") {}

    function setTarget(address t) external {
        target = IMultisend(t);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) != address(0) && !attacked && from != address(0)) {
            attacked = true;
            address[] memory r = new address[](1);
            uint256[] memory a = new uint256[](1);
            r[0] = address(this);
            a[0] = 1;
            target.sendToken(address(this), r, a); // must revert (ReentrancyGuard)
        }
    }
}

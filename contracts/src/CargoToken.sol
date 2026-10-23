// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// CARGO (X Layer). Fixed 10M cap, minted only by the miner (set once), burnable by any holder.
// No owner powers after setMinter: no pause, no blacklist, no extra mint.

contract CargoToken {
    string public constant name = "Cargo";
    string public constant symbol = "CARGO";
    uint8 public constant decimals = 18;
    uint256 public constant CAP = 10_000_000e18;

    uint256 public totalSupply;
    uint256 public totalBurned;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public minter;
    address private deployer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterSet(address minter);

    error NotAllowed();
    error CapExceeded();

    constructor() {
        deployer = msg.sender;
    }

    function setMinter(address m) external {
        if (msg.sender != deployer || minter != address(0) || m == address(0)) revert NotAllowed();
        minter = m;
        deployer = address(0);
        emit MinterSet(m);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotAllowed();
        if (totalSupply + totalBurned + amount > CAP) revert CapExceeded(); // burned supply never re-minted
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _spend(from, amount);
        _burn(from, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spend(from, amount);
        _move(from, to, amount);
        return true;
    }

    function _spend(address from, uint256 amount) private {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) private {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        totalBurned += amount;
        emit Transfer(from, address(0), amount);
    }
}

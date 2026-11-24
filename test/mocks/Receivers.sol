// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMultisend} from "./Tokens.sol";

/// Contract wallet that refuses native coins.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// Contract wallet that accepts native coins (e.g. a Safe).
contract AcceptingReceiver {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// Tries to re-enter sendNative when it receives coins.
contract ReentrantReceiver {
    IMultisend public immutable target;
    bool public reentered;

    constructor(address t) {
        target = IMultisend(t);
    }

    receive() external payable {
        address[] memory r = new address[](1);
        uint256[] memory a = new uint256[](1);
        r[0] = address(this);
        a[0] = 1;
        target.sendNative{value: msg.value}(r, a); // must revert (ReentrancyGuard)
        reentered = true;
    }
}

/// Burns all the gas it is given.
contract GasGuzzler {
    receive() external payable {
        while (true) {}
    }
}

/// Accepts coins, then returns a large blob (100 KB) that a naive caller would copy into memory.
contract ReturnBombReceiver {
    receive() external payable {
        assembly {
            return(0, 100000)
        }
    }
}

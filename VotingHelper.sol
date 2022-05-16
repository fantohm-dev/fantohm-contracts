// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Capped.sol";

interface IVotingEscrow {
    function balanceOfVotingToken(address _owner) external view returns (uint);
}

interface IwsFHM {
    function sFHMValue(uint _amount) external view returns (uint);
}

contract VotingHelper is ERC20Capped, Ownable, AccessControl {

    using SafeMath for uint;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address[] public tokens;
    address[] public wrappedTokens;
    address[] public contracts;

    constructor() ERC20Capped(1) ERC20("Voting Fantohm", "voteFHM") {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(ADMIN_ROLE, _msgSender());
    }

    /// @notice get balance of _user in sFHM 9 decimal value which is interchangeable in crosschain deployment
    /// @param account voter
    /// @return valuation in staked token for all user holdings allowable to use for voting
    function balanceOf(address account) public view override returns (uint256) {
        uint votingPower = 0;

        // compute from erc20 tokens like native token, stake token, bridged token and their historical versions, etc...
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0)) {
                uint balance = IERC20(tokens[i]).balanceOf(account);
                votingPower = votingPower.add(balance);
            }
        }

        // compute from all wrapped tokens, bridged wrapped tokens, their historical versions, etc..
        for (uint i = 0; i < wrappedTokens.length; i++) {
            if (wrappedTokens[i] != address(0)) {
                uint wrapppedBalance = IERC20(wrappedTokens[i]).balanceOf(account);
                uint balance = IwsFHM(wrappedTokens[i]).sFHMValue(wrapppedBalance);

                votingPower = votingPower.add(balance);
            }
        }

        for (uint i = 0; i < contracts.length; i++) {
            if (contracts[i] != address(0)) {
                uint balance = IVotingEscrow(contracts[i]).balanceOfVotingToken(account);

                votingPower = votingPower.add(balance);
            }
        }

        return votingPower;
    }

    function addToken(address _contract) external {
        require(hasRole(ADMIN_ROLE, _msgSender()), "Must have admin role to configure voting");

        require(_contract != address(0));
        tokens.push(_contract);
    }

    function removeToken(uint _index) external {
        require(hasRole(ADMIN_ROLE, _msgSender()), "Must have admin role to configure voting");

        tokens[_index] = address(0);
    }

    function addWrappedToken(address _contract) external {
        require(hasRole(ADMIN_ROLE, _msgSender()), "Must have admin role to configure voting");

        require(_contract != address(0));
        wrappedTokens.push(_contract);
    }

    function removeWrappedToken(uint _index) external {
        require(hasRole(ADMIN_ROLE, _msgSender()), "Must have admin role to configure voting");

        wrappedTokens[_index] = address(0);
    }

    function addContract(address _contract) external {
        require(hasRole(ADMIN_ROLE, _msgSender()), "Must have admin role to configure voting");

        require(_contract != address(0));
        contracts.push(_contract);
    }

    function removeContract(uint _index) external {
        require(hasRole(ADMIN_ROLE, _msgSender()), "Must have admin role to configure voting");

        contracts[_index] = address(0);
    }
}

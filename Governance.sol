// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/compatibility/GovernorCompatibilityBravo.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

contract Governance is
    Ownable,
    Governor,
    GovernorCompatibilityBravo,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    mapping(address => bool) public whitelisted;

    uint256 private _votingDelay;
    uint256 private _votingPeriod;
    uint256 private _proposalThreshold;

    event WhitelistedAdded(address account);
    event WhitelistedRemoved(address account);

    event VotingDelaySet(uint256 oldVotingDelay, uint256 newVotingDelay);
    event VotingPeriodSet(uint256 oldVotingPeriod, uint256 newVotingPeriod);
    event ProposalThresholdSet(uint256 oldProposalThreshold, uint256 newProposalThreshold);

    constructor(
        IVotes _token,
        TimelockController _timelock
    )
        Governor("GridMindDAO Governor")
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(30)
        GovernorTimelockControl(_timelock)
    {
        _votingDelay = 28800;
        _votingPeriod = 201600;
        _proposalThreshold = 10000e18;
    }

    function votingDelay() public view override returns (uint256) {
        return _votingDelay;
    }

    function votingPeriod() public view override returns (uint256) {
        return _votingPeriod;
    }

    function proposalThreshold() public view override returns (uint256) {
        return _proposalThreshold;
    }

    function state(
        uint256 proposalId
    )
        public
        view
        override(Governor, IGovernor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function quorum(
        uint256 blockNumber
    )
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function getVotes(
        address account,
        uint256 blockNumber
    ) public view override(Governor, IGovernor) returns (uint256) {
        return super.getVotes(account, blockNumber);
    }

    function addWhitelisted(address account) external onlyOwner {
        require(account != address(0), "account cannot be zero address");
        require(!whitelisted[account], "account already whitelisted");
        whitelisted[account] = true;
        emit WhitelistedAdded(account);
    }

    function removeWhitelisted(address account) external onlyOwner {
        require(whitelisted[account], "account not whitelisted");
        delete whitelisted[account];
        emit WhitelistedRemoved(account);
    }

    function setVotingDelay(uint256 newVotingDelay) public virtual onlyOwner {
        uint256 pre = _votingDelay;
        _votingDelay = newVotingDelay;
        emit VotingDelaySet(pre, newVotingDelay);
    }

    function setVotingPeriod(uint256 newVotingPeriod) public virtual onlyOwner {
        require(newVotingPeriod > 0, "GovernorSettings: voting period too low");
        uint256 pre = _votingPeriod;
        _votingPeriod = newVotingPeriod;
        emit VotingPeriodSet(pre, newVotingPeriod);
    }

    function setProposalThreshold(uint256 newProposalThreshold) public virtual onlyOwner {
        uint256 pre = _proposalThreshold;
        _proposalThreshold = newProposalThreshold;
        emit ProposalThresholdSet(pre, newProposalThreshold);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    )
        public
        virtual
        override(Governor, GovernorCompatibilityBravo, IGovernor)
        returns (uint256)
    {
        return Governor.propose(targets, values, calldatas, description);
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual override(Governor, IGovernor) returns (uint256) {
        require(whitelisted[_msgSender()], "account not whitelisted");
        return Governor.execute(targets, values, calldatas, descriptionHash);
    }
    
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public returns (uint256) {
        require(whitelisted[_msgSender()], "account not whitelisted");
        return _cancel(targets, values, calldatas, descriptionHash);
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        return
            super._execute(
                proposalId,
                targets,
                values,
                calldatas,
                descriptionHash
            );
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(Governor, IERC165, GovernorTimelockControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// TODO:You need to write a smart contract that implements part of the bridge infrastructure.
// This contract has a bridge function that accepts uint256 amount - the number of usdc the
// user wants to bridge, uint64 destinationChainSelector - chain selector of the network to
// which the user wants to bridge usdc. The bridge function deducts this value from the user's
// account and stores it on the current contract. After the sum of 1000 usdc is collected for a
// certain destination chain (different users call this function and the sum increases) it is
// necessary to send all tokens to another chain via ccip. Together with tokens it is necessary
// to send addresses of all users who invested usdc in this transaction. it is not necessary to
// implement logic on dst chain. You can leave _ccipReceive functions empty.
// You need to implement this on any 4 chains that support ccip. Don't forget to keep the code
// clean with clear variable names and a good refactor.

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {IRouterClient} from "src/CCIP/IRouterClient.sol";
import {Client} from "src/CCIP/libraries/Client.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatibleInterface.sol";

/// @title Smart contract that implements part of the bridge infrastructure.
/// @author Aleksei Gerasev
/// @notice This contract has a bridge function that accepts uint256 amount - the number of usdc the
/// user wants to bridge, uint64 destinationChainSelector - chain selector of the network to
/// which the user wants to bridge usdc. The bridge function deducts this value from the user's
/// account and stores it on the current contract. After the sum of 1000 usdc is collected for a
/// certain destination chain (different users call this function and the sum increases) it is
/// necessary to send all tokens to another chain via ccip. Together with tokens it is necessary
/// to send addresses of all users who invested usdc in this transaction. it is not necessary to
/// implement logic on dst chain. You can leave _ccipReceive functions empty.
/// This is only implemented on any 4 chains that support ccip.
contract Bridge is AutomationCompatibleInterface {
    //////////////
    /// Errors ///
    //////////////
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error UnsupportedChain(uint64 chainSelector);

    //////////////
    /// Events ///
    //////////////
    event TransferToAnotherChain(
        bytes32 indexed messageId, // The unique ID of the CCIP message
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        address[] usersDeposited, // Addresses of all users
        uint256[] balancesDeposited, // Balances of all users,
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

    using EnumerableSet for EnumerableSet.AddressSet;

    //////////////
    /// Types  ///
    //////////////
    struct DepositsInfo {
        uint256 totalAmount;
        EnumerableSet.AddressSet users;
    }

    //////////////////////////////
    /// Constants & Immutables ///
    //////////////////////////////
    uint256 private constant USDC_DECIMALS = 6;
    uint256 private constant TARGET_SUM = 1000 * 10 ** USDC_DECIMALS;

    IRouterClient private immutable i_router;
    LinkTokenInterface private immutable i_linkToken;
    IERC20 private immutable i_usdcContract;
    address private immutable i_receiverContract;

    ///////////////////////
    /// State variables ///
    ///////////////////////
    mapping(uint64 chain => bool supported) private s_supportedChains;
    mapping(uint64 chain => DepositsInfo deposits) private s_chainToDeposited;
    mapping(uint64 chain => mapping(address user => uint256 balance))
        private s_usdcBalances;

    /////////////////
    /// Modifiers ///
    /////////////////
    modifier onlySupportedChains(uint64 chain) {
        if (!s_supportedChains[chain]) {
            revert UnsupportedChain(chain);
        }
        _;
    }

    constructor(
        address rounterAddr,
        address linkTokenAddr,
        address usdcTokenAddr,
        address receiverContract,
        uint64[] memory supportedChains
    ) {
        i_router = IRouterClient(rounterAddr);
        i_linkToken = LinkTokenInterface(linkTokenAddr);
        i_usdcContract = IERC20(usdcTokenAddr);
        i_receiverContract = receiverContract;

        for (uint256 i; i < supportedChains.length; ) {
            s_supportedChains[supportedChains[i]] = true;
            unchecked {
                ++i;
            }
        }
    }

    //////////////////////////
    /// External functions ///
    //////////////////////////

    /// @notice Bridges usdc to another chain
    /// @param amount The amount of usdc to bridge
    /// @param destinationChainSelector The destination chain selector
    /// @notice The user account has to approve the amount of usdc on address(this)
    function bridgeUsdcToAnotherChain(
        uint256 amount,
        uint64 destinationChainSelector
    ) external onlySupportedChains(destinationChainSelector) {
        //transferFrom user account to address(this) with amount
        i_usdcContract.transferFrom(msg.sender, address(this), amount);

        //update balance of user in usdc
        s_usdcBalances[destinationChainSelector][msg.sender] += amount;

        // update total amount for destination chain
        s_chainToDeposited[destinationChainSelector].totalAmount += amount;

        //add user to deposits(even if it was already there)
        if (
            !s_chainToDeposited[destinationChainSelector].users.contains(
                msg.sender
            )
        ) {
            s_chainToDeposited[destinationChainSelector].users.add(msg.sender);
        }

        if (
            s_chainToDeposited[destinationChainSelector].totalAmount >=
            TARGET_SUM
        ) {
            // get users and balances for destination chain
            (
                address[] memory users,
                uint256[] memory balances
            ) = _getUsersAndBalances(destinationChainSelector);
        }
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        //get chain selector
        uint64 chainSelector = abi.decode(checkData, (uint64));

        upkeepNeeded =
            s_chainToDeposited[chainSelector].totalAmount >= TARGET_SUM;
        // We don't use the checkData in this example. The checkData is defined when the Upkeep was registered.
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        uint64 chainSelector = abi.decode(performData, (uint64));

        if (s_chainToDeposited[chainSelector].totalAmount >= TARGET_SUM) {
            (
                address[] memory users,
                uint256[] memory balances
            ) = _getUsersAndBalances(chainSelector);

            // send to CCIP
            _sendToCCIP(chainSelector, i_receiverContract, users, balances);
        }
    }

    /// @param destinationChainSelector The destination chain
    /// @param receiver The receiver smart contract
    /// @param users The users array to be sent
    /// @param balances The users balances array to be sent
    function _sendToCCIP(
        uint64 destinationChainSelector,
        address receiver,
        address[] memory users,
        uint256[] memory balances
    ) private returns (bytes32 messageId) {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(i_usdcContract), // USDC token address
            amount: s_chainToDeposited[destinationChainSelector].totalAmount // USDC amount to be sent
        });

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), // ABI-encoded receiver address
            data: abi.encode(users, balances), // ABI-encoded array of user addresses and balances
            tokenAmounts: tokenAmounts, //Array indicating the token and amount to be sent
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            // Set the feeToken  address, indicating LINK will be used for fees
            feeToken: address(i_linkToken)
        });

        // Get the fee required to send the message
        uint256 fees = i_router.getFee(
            destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > i_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(i_linkToken.balanceOf(address(this)), fees);

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        i_linkToken.approve(address(i_router), fees);

        // send to CCIP
        messageId = i_router.ccipSend(destinationChainSelector, evm2AnyMessage);

        // emit event
        emit TransferToAnotherChain(
            messageId,
            destinationChainSelector,
            receiver, // The receiver(smart contract) of the CCIP message
            users,
            balances,
            address(i_linkToken),
            fees // The fees paid for sending the CCIP message
        );
    }

    //////////////////////////////
    /// Private View functions ///
    /////////////////////////////

    function _getUsersAndBalances(
        uint64 destinationChainSelector
    ) private view returns (address[] memory, uint256[] memory) {
        address[] memory users = s_chainToDeposited[destinationChainSelector]
            .users
            .values();
        uint256[] memory balances = new uint256[](users.length);

        for (uint256 i; i < users.length; ) {
            balances[i] = s_usdcBalances[destinationChainSelector][users[i]];
            unchecked {
                ++i;
            }
        }

        return (users, balances);
    }
}

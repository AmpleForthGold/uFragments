pragma solidity 0.4.24;

import "openzeppelin-eth/contracts/ownership/Ownable.sol";

import "./UFragments.sol";
import "./RebaseDelta.sol";

//==Developed and deployed by the AmpleForthGold Team: https://ampleforth.gold
//  With thanks to:  
//         https://github.com/Auric-Goldfinger
//         https://github.com/z0sim0s
//         https://github.com/Aurum-hub

/**
 * @title Orchestrator 
 * @notice The orchestrator is the main entry point for rebase operations. It coordinates the rebase
 * actions with external consumers (price oracles) and provides timing / access control for when a 
 * rebase occurs.
 * 
 * Orchestrator is based on Ampleforth.org implmentation with modifications by the AmpleForthgold team.
 * It is a merge and modification of the Orchestrator.sol and UFragmentsPolicy.sol from the original 
 * Ampleforth project. Thanks to the Ampleforth.org team!
 *
 * Code ideas also come from the RMPL.IO (RAmple Project), YAM team and BASED team. 
 * Thanks to the all whoose ideas we stole! 
 * 
 * We have simplifed the design to lower the gas fees. In some places we have removed things that were
 * "nice to have" because of the cost of GAS. Specifically we have lowered the number of events and 
 * hard coded things that we know are going to be constant (such as not looking up a uniswap pair,
 * we just pass the pair pointer into the contract). This was done to save GAS and lower the execution
 * cost of the contract.
 *
 * The Price used for rebase calculations shall be sourced from Uniswap (on chain liquidity pools).
 * 
 * Relying on price Oracles (either on chain or off chain) will never be perfect. Oracles go bad, 
 * others come good. At present we will use liquidity pools on uniswap to provide the oracles
 * for pricing. However those oracles may go bad and need to be replaced. We think that oracle 
 * failure in the short term is unlikly, but not impossible. In the long term it may be likely
 * to see oracle failure. Due to this the contract 'owners' (the AmpleForthGold team) shall 
 * have an 'off switch' in the code to disable and override rebase operations. At some point 
 * it may be needed...but we hope it is not needed.  
 *      
 */
contract Orchestrator is Ownable {

    using SafeMath for uint16;
    using SafeMath for uint256;
    using SafeMathInt for int256;
    
    // The ERC20 Token for ampleforthgold
    UFragments public afgToken = UFragments(0x8E54954B3Bbc07DbE3349AEBb6EAFf8D91Db5734);
    
    // oracle configuration - see RebaseDelta.sol for details.
    RebaseDelta public oracle = RebaseDelta(0xF09402111AF6409B410A8Dd07B82F1cd1674C55F);
    IUniswapV2Pair public tokenPairX = IUniswapV2Pair(0x2d0C51C1282c31d71F035E15770f3214e20F6150);
    IUniswapV2Pair public tokenPairY = IUniswapV2Pair(0x9C4Fe5FFD9A9fC5678cFBd93Aa2D4FD684b67C4C);
    bool public flipX = false;
    bool public flipY = false;
    uint8 public decimalsX = 9;
    uint8 public decimalsY = 9;
    
    // The timestamp of the last rebase event generated from this contract.
    // Technically another contract cauld also cause a rebase event, 
    // so this cannot be relied on globally. uint64 should not clock
    // over in forever. 
    uint64 public lastRebase = uint64(0);

    // The number of rebase cycles since inception. Why the original
    // designers did not keep this inside uFragments is a question
    // that really deservers an answer? We can use a uint16 cause we
    // will be about 179 years old before it clocks over. 
    uint16 public epoch = 3;

    // Transactions are used to generate call back to DEXs that need to be 
    // informed about rebase events. Specifically with uniswap the function
    // on the IUniswapV2Pair.sync() needs to be called so that the 
    // liquidity pool can reset it reserves to the correct value.  
    // ...Stable transaction ordering is not guaranteed.
    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
    }
    event TransactionFailed(address indexed destination, uint index, bytes data);
    Transaction[] public transactions;
    
    /**
     * Just initializes the base class.
     */
    constructor() 
        public {
        Ownable.initialize(msg.sender);
    }

    /**
     * @notice Owner entry point to initiate a rebase operation.
     * @param supplyDelta the delta as passed to afgToken.rebase.
     *        (the delta needs to be calulated off chain or by the 
     *        calling contract).
     * @param disable_ passing true will disable the ability of 
     *        users (other then the owner) to cause a rebase.
     *
     * The owner can always generate a rebase operation. At some point in the future
     * the owners keys shall be burnt. However at this time (and until we are certain
     * everthing is working as it should) the owners shall keep their keys.
     * The ability for the owners to generate a rebase of any value at any time is a 
     * carry over from the original ampleforth project. This function is just a little
     * more direct.  
     */ 
    function ownerForcedRebase(int256 supplyDelta, bool disable_)
        external
        onlyOwner
    {
        /* If lastrebase is set to 0 then *users* cannot cause a rebase. 
         * This should allow the owner to disable the auto-rebase operations if
         * things go wrong (see things go wrong above). */
        if (disable_) {
            lastRebase = uint64(0);
        } else {
            lastRebase = uint64(block.timestamp);
        }
         
        afgToken.rebase(epoch.add(1), supplyDelta);
        popTransactionList();
    }

    /**
     * @notice Main entry point to initiate a rebase operation.
     *         On success returns the new supply value.
     */
    function rebase()
        external
        returns (uint256)
    {
        // The owner shall call this member for the following reasons:
        //   (1) Something went wrong and we need a rebase now!
        //   (2) At some random time at least 24 hours, but no more then 48
        //       hours after the last rebase.  
        if (Ownable.isOwner())
        {
            return internal_rebase();
        }

        // we require at least 1 owner rebase event prior to being enabled!
        require (lastRebase != uint64(0));        

        // at least 24 hours shall have passed since the last rebase event.
        require (lastRebase + 1 days < uint64(block.timestamp));

        // if more then 48 hours have passed then allow a rebase from anyone
        // willing to pay the GAS.
        if (lastRebase + 2 days < uint64(block.timestamp))
        {
            return internal_rebase();
        }

        // There is (currently) no way of generating a random number in a 
        // contract that cannot be seen/used by the miner. Thus a big miner 
        // could use information on a rebase for their advantage. We do not
        // want to give any advantage to a big miner over a little trader,
        // thus the traders ability to generate and see a rebase (ahead of time)
        // should be about the same as a that of a large miners.
        //
        // If (in the future) the ability to provide true randomeness 
        // changes then we would like to re-write this bit of code to provide
        // true random rebases where no one gets an advantage. 
        // 
        // A day after the last rebase, anyone can call this rebase function
        // to generate a rebase. However to give it a little bit of complexity 
        // and mildly lower the ability of traders/miners to take advantage 
        // of the rebase we will set the *fair* odds of a rebase() call
        // succeeding at 20%. Of course it can still be gamed, but this 
        // makes gaming it just that little bit harder.
        // 
        // MINERS: To game it the miner would need to adjust his coinbase to 
        // correctly solve the xor with the preceeding block hashs,
        // That is do-able, but the miner would need to go out of there
        // way to do it...but no perfect solutions so this is it at the
        // moment.  
        //
        // TRADERS: To game it they could just call this function many times
        // until it triggers. They have a 20% chance of triggering each 
        // time they call it. They could get lucky, or they could burn a lot of 
        // GAS. Whatever they do it will be obvious from the many calls to this
        // function. 
        uint256 odds = uint256(blockhash(block.number - 1)) ^ uint256(block.coinbase);
        if ((odds % uint256(5)) == uint256(1))
        {
            return internal_rebase(); 
        }      

        // no change, no rebase!
        return uint256(0);
    }

    /**
     * @notice Internal entry point to initiate a rebase operation.
     *         If we get here then a rebase call to the erc20 token 
     *         will occur.
     * 
     *         returns the new supply value.
     */
    function internal_rebase() 
        private 
        returns(uint256) {
        lastRebase = uint64(block.timestamp);
        uint256 z = afgToken.rebase(epoch.add(1), calculateRebaseDelta(true));
        popTransactionList();
        return z;
    }

    /**
     * @notice Configures the oracle & information passed to the oracle 
     *         to calculate the rebase. See RebaseDelta for definition
     *         of params.
     *      
     *         Initially tokenPairX is the uniswap pair for AAU/WETH
     *         and tokenPairY is the uniswap pair for PAXG/WETH.
     *         These addresses can be verified on etherscan.io.
     */
    function configureOracle(IUniswapV2Pair tokenPairX_,
                      bool flipX_,
                      uint8 decimalsX_,
                      IUniswapV2Pair tokenPairY_,
                      bool flipY_,
                      uint8 decimalsY_,
                      RebaseDelta oracle_)
        external
        onlyOwner
        {
            tokenPairX = tokenPairX_;
            flipX = flipX_;
            decimalsX = decimalsX_;
            tokenPairY = tokenPairY_;
            flipY = flipY_;
            decimalsY = decimalsY_;
            oracle = oracle_;
    }

    /**
     * @notice tries to calculate a rebase based on the configured oracle info. 
     *
     * @param limited_ passing true will limit the rebase based on the 5% rule. 
     */
    function calculateRebaseDelta(bool limited_) 
        public
        view 
        returns (int256) 
        { 
            require (afgToken != UFragments(0));
            require (oracle != RebaseDelta(0));
            require (tokenPairX != IUniswapV2Pair(0));
            require (tokenPairY != IUniswapV2Pair(0));
            require (decimalsX != uint8(0));
            require (decimalsY != uint8(0));
            
            uint256 supply = afgToken.totalSupply();
            int256 delta = - oracle.calculate(
                tokenPairX,
                flipX,
                decimalsX,
                supply, 
                tokenPairY,
                flipY,
                decimalsY);

            if (!limited_) {
                // Unlimited (brutal) rebase.
                return delta;
            }   

            if (delta == int256(0))
            {
                // no rebase needed!
                return int256(0);
            }

            /** 5% rules: 
             *      (1) If the price is in the +-5% range do not rebase at all. This 
             *          allows the market to fix the price to within a 10% range.
             *      (2) If the price is within +-10% range then only rebase by 1%.
             *      (3) If the price is more then +-10% then the change shall be half the 
             *          delta. i.e. if the price diff is -28% then the change will be -14%.
             */
            int256 supply5p = int256(supply.div(uint256(20))); // 5% == 5/100 == 1/20
   
            if (delta < int256(0)) {
                if (-delta < supply5p) {
                    return int256(0); // no rebase: 5% rule (1)
                }
                if (-delta < supply5p.mul(int256(2))) {
                    return (-supply5p).div(int256(5)); // -1% rebase
                }
            } else {
                if (delta < supply5p) {
                    return int256(0); // no rebase: 5% rule (1)
                }
                if (delta < supply5p.mul(int256(2))) {
                    return supply5p.div(int256(5)); // +1% rebase
                }
            }

            return (delta.div(2)); // half delta rebase
    }

    // for testing purposes only!
    // winds back time a day at a time. 
    function windbacktime() 
        public
        onlyOwner {         
        require (lastRebase > 1 days);
        lastRebase-= 1 days;
    }

    //===TRANSACTION FUNCTIONALITY (mostly identical to original Ampleforth implementation)

    /* generates callbacks after a rebase */
    function popTransactionList()
        private
    {
        // we are getting an AAU price feed from this uniswap pair, thus when the rebase occurs 
        // we need to ask it to rebase the AAU tokens in the pair. We always know this needs
        // to be done, so no use making a transcation for it.
        if (tokenPairX != IUniswapV2Pair(0)) {  
            tokenPairX.sync();
        }

        // iterate thru other interested parties and generate a call to update their 
        // contracts. 
        for (uint i = 0; i < transactions.length; i++) {
            Transaction storage t = transactions[i];
            if (t.enabled) {
                bool result =
                    externalCall(t.destination, t.data);
                if (!result) {
                    emit TransactionFailed(t.destination, i, t.data);
                    revert("Transaction Failed");
                }
            }
        }
    } 

    /**
     * @notice Adds a transaction that gets called for a downstream receiver of rebases
     * @param destination Address of contract destination
     * @param data Transaction data payload
     */
    function addTransaction(address destination, bytes data)
        external
        onlyOwner
    {
        transactions.push(Transaction({
            enabled: true,
            destination: destination,
            data: data
        }));
    }

    /**
     * @param index Index of transaction to remove.
     *              Transaction ordering may have changed since adding.
     */
    function removeTransaction(uint index)
        external
        onlyOwner
    {
        require(index < transactions.length, "index out of bounds");

        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }

        transactions.length--;
    }

    /**
     * @param index Index of transaction. Transaction ordering may have changed since adding.
     * @param enabled True for enabled, false for disabled.
     */
    function setTransactionEnabled(uint index, bool enabled)
        external
        onlyOwner
    {
        require(index < transactions.length, "index must be in range of stored tx list");
        transactions[index].enabled = enabled;
    }

    /**
     * @return Number of transactions, both enabled and disabled, in transactions list.
     */
    function transactionsSize()
        external
        view
        returns (uint256)
    {
        return transactions.length;
    }

    /**
     * @dev wrapper to call the encoded transactions on downstream consumers.
     * @param destination Address of destination contract.
     * @param data The encoded data payload.
     * @return True on success
     */
    function externalCall(address destination, bytes data)
        internal
        returns (bool)
    {
        bool result;
        assembly {  // solhint-disable-line no-inline-assembly
            // "Allocate" memory for output
            // (0x40 is where "free memory" pointer is stored by convention)
            let outputAddress := mload(0x40)

            // First 32 bytes are the padded length of data, so exclude that
            let dataAddress := add(data, 32)

            result := call(
                // 34710 is the value that solidity is currently emitting
                // It includes callGas (700) + callVeryLow (3, to pay for SUB)
                // + callValueTransferGas (9000) + callNewAccountGas
                // (25000, in case the destination address does not exist and needs creating)
                sub(gas, 34710),


                destination,
                0, // transfer value in wei
                dataAddress,
                mload(data),  // Size of the input, in bytes. Stored in position 0 of the array.
                outputAddress,
                0  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }
}

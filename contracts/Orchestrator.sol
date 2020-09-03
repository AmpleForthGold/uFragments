pragma solidity 0.4.24;

import "openzeppelin-eth/contracts/ownership/Ownable.sol";

import "./UFragments.sol";
import "./RebaseDelta.sol";


/**
 * @title Orchestrator 
 * @notice The orchestrator is the main entry point for rebase operations. It coordinates the rebase
 * actions with external consumers (price oracles) and provides timing / access control for when a 
 * rebase occurs.
 * 
 * Orchestrator is based on Ampleforth.org implmentation with modifications by the AmpleForthgold team.
 * It is a merge and modification of the Orchestrator.sol and UFragmentsPolicy.sol from the original 
 * Ampleforth project. Thansk to the Ampleforth.org team!
 *
 * Code snippets & ideas also come from the RMPL.IO (RAmple Project), YAM team and BASED team. 
 * Thanks to the all whoose ideas we stole! 
 *
 * Transactions have been removed because of cost (GAS) and to lower the complexity of the contract.
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

    using SafeMath for uint256;
    using SafeMathInt for int256;
  //  using UInt256Lib for uint256;

    // the ERC20 Token for ampleforthgold
    UFragments public afgToken;

    // The timestamp of the last rebase event generated from this contract.
    // Technically another contract cauld also cause a rebase event, 
    // so this cannot be relied on globally.
    uint64 public lastRebase = uint64(0);

    // oracle configuration - see RebaseDelta.sol for details.
    IUniswapV2Pair public tokenPairX = IUniswapV2Pair(0);
    bool public flipX = false;
    uint8 public decimalsX = 9;
    IUniswapV2Pair public tokenPairY = IUniswapV2Pair(0);
    bool public flipY = false;
    uint8 public decimalsY = 9;
    RebaseDelta public oracle = RebaseDelta(0);

    /**
     * @param afgToken_ Address of the Ampleforthgold UFragments ERC20 token.
     */
    constructor(address afgToken_) 
        public {
        Ownable.initialize(msg.sender);
        afgToken = UFragments(afgToken_);
    }

    /**
     * @notice Owner entry point to initiate a rebase operation.
     * @param supplyDelta the delta as passed to afgToken.rebase.
     *        (the delta needs to be calulated off chain).
     * @param disable_ passing true will disable the ability of 
     *        users (other then the owner) to cause a rebase.
     *
     * The owner can always generate a rebase operation. At some point in the future
     * the owners keys shall be burnt. However at this time (and until we a certain
     * everthing is working as it should) the owners shall keep their keys.
     * The ability for the owners to generate a rebase of any value at any time is a 
     * carry over from the original ampleforth project. This function is just a little
     * more direct.  
     */ 
    function godMode(int256 supplyDelta, bool disable_)
        external
        onlyOwner
        returns (uint256)
    {
        require (msg.sender == tx.origin);

        /* If lastrebase is set to 0 then *users* cannot cause a rebase. 
         * This should allow the owner to disable the auto-rebase operations if
         * things go wrong (see things go wrong above). */
        if (disable_) {
            lastRebase = uint64(0);
        } else {
            lastRebase = uint64(block.timestamp);
        }
         
        return afgToken.rebase(block.timestamp, supplyDelta);
    }

    /**
     * @notice Main entry point to initiate a rebase operation.
     */
    function rebase()
        external
        returns (uint256)
    {
        // The owner shall call this member for the following reasons:
        //   (1) Something went wrong and we need a rebase now!
        //   (2) At some random time at least 24 hours, but no more then 48
        //       hours after the last rebase.  
        if ((msg.sender == tx.origin) && Ownable.isOwner())
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
        // After 1 day, anyone can call this rebase function to generate 
        // a rebase. However to give it a little bit of complexity and 
        // mildly lower the ability of traders/miners to take advantage 
        // of the rebase we will set the *fair* odds of a rebase() call
        // succeeding at 20%. Of course it can still be gamed, but this 
        // makes gaming it just that little bit harder.
        // 
        // To game it the miner would need to adjust his coinbase to 
        // correctly solve the xor with the preceeding block hashs,
        // That is do-able, but the miner would need to go out of there
        // way to do it...but no perfect solutions so this is it at the
        // moment.  
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
     */
    function internal_rebase() 
        private 
        returns(uint256) {
        lastRebase = uint64(block.timestamp);
        return afgToken.rebase(block.timestamp, calculateRebaseDelta(true));
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
        returns (int256) 
        { 
            require (afgToken != UFragments(0));
            require (oracle != RebaseDelta(0));
            require (tokenPairX != IUniswapV2Pair(0));
            require (tokenPairY != IUniswapV2Pair(0));
            require (decimalsX != uint8(0));
            require (decimalsY != uint8(0));
            
            uint256 supply = afgToken.totalSupply();
            int256 delta = oracle.calculate(
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
             *      (1) Never rebase more then 5%. 
             *      (2) If the price is in the +-5% range do not rebase at all. This 
             *          allows the market to fix the price to within a 10% range.
             *      (3) If the price is within +-10% range then only rebase by 1%.
             */
            int256 supply5p = int256(supply.div(uint256(20))); // 5% == 5/100 == 1/20
            require (supply5p != int256(0));

            if (delta < int256(0)) {
                if (-delta < supply5p) {
                    return int256(0);
                }
                if (-delta < supply5p.mul(int256(2))) {
                    return (-supply5p).div(int256(5)); // 1%
                }
                return -supply5p;
            } else {
                if (delta < supply5p) {
                    return int256(0);
                }
                if (delta < supply5p.mul(int256(2))) {
                    return supply5p.div(int256(5)); // 1%
                }
                return supply5p;
            }

            // should never get here....
            require(false);
    }

    // for testing purposes only!
    // winds back time a day at a time. 
    function windbacktime() 
        public
        onlyOwner { 
            if (lastRebase != uint64(0)) {
                lastRebase-= 1 days;
        }
    }
}

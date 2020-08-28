pragma solidity ^0.4.24;

import "zos-lib/contracts/Initializable.sol";
import "openzeppelin-eth/contracts/token/ERC20/SafeERC20.sol";
//import "openzeppelin-eth/contracts/token/ERC20/TokenTimelock.sol";

// Based on @openzeppelin TokenTimeLock.sol
// Modifications by the AmpleForthGold team.  

/**
 * @title TokenTimelock
 * @dev TokenTimelock is a token holder contract that will allow a
 * beneficiary to extract the tokens after a given release time
 */
contract TokenTimelock is Initializable {
  using SafeERC20 for IERC20;

  // ERC20 basic token contract being held
  IERC20 private _token;

  // beneficiary of tokens after they are released
  address private _beneficiary;

  // timestamp when token release is enabled
  uint256 private _releaseTime;  

  function initialize(
    IERC20 token,
    address beneficiary,
    uint256 releaseTime
  )
    public
    initializer
  {
    // solium-disable-next-line security/no-block-members
    require(releaseTime > block.timestamp);
    _token = token;
    _beneficiary = beneficiary;
    _releaseTime = releaseTime;
  }

  /**
   * @return the token being held.
   */
  function token() public view returns(IERC20) {
    return _token;
  }

  /**
   * @return the beneficiary of the tokens.
   */
  function beneficiary() public view returns(address) {
    return _beneficiary;
  }

  /**
   * @return the time when the tokens are released.
   */
  function releaseTime() public view returns(uint256) {
    return _releaseTime;
  }

  /**
   * @notice Transfers tokens held by timelock to beneficiary.
   */
  function release() public {
    // solium-disable-next-line security/no-block-members
    require(block.timestamp >= _releaseTime);

    uint256 amount = _token.balanceOf(address(this));
    require(amount > 0);

    _token.safeTransfer(_beneficiary, amount);
  }

  /**
   * increaseReleaseTime() can be used to increase the release time.
   * 
   * It is designed to allow the lock to be re-used, but will not 
   * allow/stops changes to any active lock.
   *   
   *     - only the benificary can change this.
   *     - The lock must have 0 balance to change.
   *
   * Not as secure as the original, but allows for some flexibility and
   * re-use of the contract which has become important in these high 
   * GAS fee days. 
   */
  function increaseReleaseTime(uint256 newReleaseTime) public  {
      
      // Only the benificary can move the time
      require (msg.sender == _beneficiary);

      // Must be in the future
      require (newReleaseTime > block.timestamp );

      // Must not be too far in the future (stops integer overflow attacks)
      require (newReleaseTime < block.timestamp + 2000 days);

      // Must be more in the future then the current release time 
      require (newReleaseTime > _releaseTime );

      // can only be increased if there is no funds in the lock
      uint256 amount = _token.balanceOf(address(this));
      require(amount == 0);

      _releaseTime = newReleaseTime;
  }

  uint256[50] private ______gap;
}

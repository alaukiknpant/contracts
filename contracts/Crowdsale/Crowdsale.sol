//SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

/**
 * @title Crowdsale
 * @dev Crowdsale is a base contract for managing the Co-museum crowdsale,
 * allowing investors to purchase tokens with ERC20 compliant stablecoins including USDC and USDT. 
 * This contract implements such functionality in its most fundamental form 
 * and can be extended to provide additional functionality and/or custom behavior.
 * The external interface represents the basic interface for purchasing tokens, and 
 * conforms the base architecture for Co-museum crowdsales. The internal interface 
 * conforms the extensible and modifiable surface of crowdsales. Override
 * the methods to add functionality. Consider using 'super' where appropriate to concatenate
 * behavior.
 */
contract Crowdsale is Context, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // The token being sold
    IERC20 private _token;

     // The USDC instance the contract will accept as a valid means of payment
    IERC20 public _usdc;

    // The USDT instance the contract will accept as a valid means of payment
    IERC20 public _usdt;

    // Address where funds are collected
    address payable private _wallet;

    // How many token units a buyer gets per USDC.
    // The rate is the conversion between the smallest and indivisible USDC and the smallest and indivisible token unit.
    // USDC has 6 decimal places
    // So, if you are using a rate of 1 with a ERC20Detailed token with 6 decimals called TOK
    // 0.000001 USDC will give you 1 unit, or 0.000001 TOK.
    uint256 private _rate;

    // Amount of usdc raised
    uint256 private _usdcRaised;

    // Amount of usdt raised
    uint256 private _usdtRaised;

    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokensPurchased(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);

    /**
     * @param r Number of token units a buyer gets per usdc/usdt
     * @dev The rate is the conversion between the smallest and indivisible unit of
     * usdt/usdc and the smallest and indivisible token unit.
     * For example, if you are using a rate of 1 with a ERC20Detailed token
     * with 6 decimals called TOK, 1 * 10 ^ (-6) USDC/USDT will give you 1 unit, or 1 * 10 ^ (-6) TOK.
     * We are assuming that our token has 6 decimal places in the example above.
     * @param w Address where collected funds will be forwarded to
     * @param t Address of the token being sold
     * @param usdc Address of the usdc being accepted as payment
     * @param usdt Address of the usdt being accepted as payment
     */
    constructor (uint256 r, address payable w, address t, address usdc, address usdt) {
        require(r > 0, "Crowdsale: rate is 0");
        require(w != address(0), "Crowdsale: wallet is the zero address");
        require(address(t) != address(0), "Crowdsale: token is the zero address");

        _rate = r;
        _wallet = w;
        _token = IERC20(t);
        _usdc = IERC20(usdc);
        _usdt = IERC20(usdt);
}

    /**
     * @dev replacement for fallback function ***DO NOT OVERRIDE***
     * Note that other contracts will transfer funds with a base gas stipend
     * of 2300, which is not enough to call buyTokens. Consider calling
     * buyTokens directly when purchasing tokens from a contract.
     */
    event Received(address, uint);
    receive() external payable {
        emit Received(msg.sender, msg.value);
        // buyTokens(_msgSender(), 1);
}

    /**
     * @return the token being sold.
     */
    function token() public view returns (IERC20) {
        return _token;
    }

    /**
     * @return the address where funds are collected.
     */
    function wallet() public view returns (address payable) {
        return _wallet;
    }

    /**
     * @return the number of token units a buyer gets per smallest unit of usdc/usdt.
     */
    function rate() public view returns (uint256) {
        return _rate;
    }

    /**
     * @return the amount of usdc raised - this number has to be divided by 10^6 by the user..
     */
    function usdcRaised() public view returns (uint256) {
        return _usdcRaised;
    }

    /**
     * @return the amount of usdt raised - this number has to be divided by 10^6 by the user..
     */
    function usdtRaised() public view returns (uint256) {
        return _usdtRaised;
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * This function has a non-reentrancy guard, so it shouldn't be called by
     * another `nonReentrant` function.
     * @param beneficiary Recipient of the token purchase
     */
    function buyTokens(address beneficiary, uint256 usdAmount, IERC20 stablecoin) public virtual nonReentrant payable {
        _preValidatePurchase(beneficiary, usdAmount, stablecoin);
    
        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(usdAmount);

        // update state
        if (stablecoin == _usdc) {
            // transfer usdc to our wallet
            _usdc.transferFrom( msg.sender, _wallet, usdAmount);

            _usdcRaised = _usdcRaised.add(usdAmount);
        } else if (stablecoin == _usdt) {
            // transfer usdt to our wallet
            _usdt.transferFrom( msg.sender, _wallet, usdAmount);
        } 
        
        _processPurchase(beneficiary, tokens);
        emit TokensPurchased(_msgSender(), beneficiary, usdAmount, tokens);

        _updatePurchasingState(beneficiary, usdAmount);

        // _forwardFunds();
        _postValidatePurchase(beneficiary, usdAmount);
    }

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met.
     * Use `super` in contracts that inherit from Crowdsale to extend their validations.
     * Example from CappedCrowdsale.sol's _preValidatePurchase method:
     *     super._preValidatePurchase(beneficiary, weiAmount);
     *     require(weiRaised().add(weiAmount) <= cap);
     * @param beneficiary Address performing the token purchase
     * @param usdAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address beneficiary, uint256 usdAmount, IERC20 stablecoin) virtual internal view {
        require(beneficiary != address(0), "Beneficiary is the zero address");
        require(usdAmount != 0, "usdAmount is 0");
        require(_usdc == stablecoin || _usdt == stablecoin, "Incorrect stablecoin provided");

        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
    }

    /**
     * @dev Validation of an executed purchase. Observe state and use revert statements to undo rollback when valid
     * conditions are not met.
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _postValidatePurchase(address beneficiary, uint256 weiAmount) virtual internal view {
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     * @dev Source of tokens. Override this method to modify the way in which the crowdsale ultimately gets and sends
     * its tokens.
     * @param beneficiary Address performing the token purchase
     * @param tokenAmount Number of tokens to be emitted
     */
    function _deliverTokens(address beneficiary, uint256 tokenAmount) virtual internal {
        _token.safeTransfer(beneficiary, tokenAmount);
    }

    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Doesn't necessarily emit/send
     * tokens.
     * @param beneficiary Address receiving the tokens
     * @param tokenAmount Number of tokens to be purchased
     */
    function _processPurchase(address beneficiary, uint256 tokenAmount) virtual internal {
        _deliverTokens(beneficiary, tokenAmount);
    }

    /**
     * @dev Override for extensions that require an internal state to check for validity (current user contributions,
     * etc.)
     * @param beneficiary Address receiving the tokens
     * @param usdAmount Value in usdc involved in the purchase
     */
    function _updatePurchasingState(address beneficiary, uint256 usdAmount) virtual internal {
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     * @dev Override to extend the way in which ether is converted to tokens.
     * @param usdAmount Value of usdc to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _weiAmount
     */
    function _getTokenAmount(uint256 usdAmount) virtual internal view returns (uint256) {
        return usdAmount.mul(_rate);
    }

    /**
     * @dev Determines how ETH is stored/forwarded on purchases.
     */
    // function _forwardFunds() internal {
    //     _wallet.transfer(msg.value);
    // }
}

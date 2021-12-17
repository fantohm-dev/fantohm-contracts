// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

interface IBurnable {
    function burnFrom(address account_, uint256 amount_) external;
}

interface IUniswapV2ERC20 {
    function totalSupply() external view returns (uint);
}

interface IUniswapV2Pair is IUniswapV2ERC20 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns ( address );
    function token1() external view returns ( address );
}

contract FHUDMinter is Ownable, AccessControl {
    using SafeMath for uint256;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address public fhmAddress;
    address public fhudAddress;

    address public fhmLpAddress;
    uint256 public decimals;
    bool public doDiv;

    event FHUDMinted(
        uint256 timestamp,
        address minter,
        uint256 fhmAmountBurnt,
        uint256 fhudAmountMinted
    );

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MINTER_ROLE, _msgSender());
    }

    /**
     * 2 decimals
     */
    function getMarketPrice() public view returns (uint256) {
        ( uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair( fhmLpAddress ).getReserves();
        if ( IUniswapV2Pair( fhmLpAddress ).token0() == fhmAddress ) {
            if (doDiv) return reserve1.div(reserve0).div( 10**decimals );
            else return reserve1.mul( 10**decimals ).div(reserve0);
        } else {
            if (doDiv) return reserve0.div(reserve1).div( 10**decimals );
            else return reserve0.mul( 10**decimals ).div(reserve1);
        }
    }

    function getFhmAmount(uint256 stableCoinAmount, uint256 marketPrice) public view returns (uint256) {
        return stableCoinAmount.div(marketPrice.div(10**2)).div(10**9);
    }

    /**
     * stableCoinAmount - 18 decimals
     * minimalTokenPrice - 2 decimals
     */
    // 10,000 usd / 100.00 usd/fhm
    // 10,000.000,000,000,000,000,000 / 100.00
    function mint(uint256 stableCoinAmount, uint256 minimalTokenPrice) external virtual {
        require(hasRole(MINTER_ROLE, _msgSender()), "FHUDMinter: must have minter role to mint");

        uint256 marketPrice = getMarketPrice();
        require(marketPrice >= minimalTokenPrice, "Slip page not met");

        uint256 fhmAmount = getFhmAmount(stableCoinAmount, marketPrice);
        IBurnable(fhmAddress).burnFrom(msg.sender, fhmAmount);
        IMintable(fhudAddress).mint(msg.sender, stableCoinAmount);

        emit FHUDMinted(block.timestamp, msg.sender, fhmAmount, stableCoinAmount);

    }

    function setFhmAddress(address _fhmAddress) external virtual onlyOwner {
        fhmAddress = _fhmAddress;
    }

    function setFhudAddress(address _fhudAddress) external virtual onlyOwner {
        fhudAddress = _fhudAddress;
    }

    function setFhmLpAddress(address _fhmLpAddress, uint256 _decimals, bool _doDiv) external virtual onlyOwner {
        fhmLpAddress = _fhmLpAddress;
        decimals = _decimals;
        doDiv = _doDiv;
    }

    function recoverTokens(address token) external virtual onlyOwner {
        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function recoverEth() external virtual onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

}

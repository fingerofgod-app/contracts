// SPDX-License-Identifier: MIT

/*
 *  This contract is open source under the MIT License.
 *  Snake Finance licensing claims? We love you, but we’re forging our own path.
 *  Feel free to copy, modify, or build upon this code.

 ########:'####:'##::: ##::'######:::'########:'########::::::'#######::'########:::::'######::::'#######::'########::
 ##.....::. ##:: ###:: ##:'##... ##:: ##.....:: ##.... ##::::'##.... ##: ##.....:::::'##... ##::'##.... ##: ##.... ##:
 ##:::::::: ##:: ####: ##: ##:::..::: ##::::::: ##:::: ##:::: ##:::: ##: ##:::::::::: ##:::..::: ##:::: ##: ##:::: ##:
 ######:::: ##:: ## ## ##: ##::'####: ######::: ########::::: ##:::: ##: ######:::::: ##::'####: ##:::: ##: ##:::: ##:
 ##...::::: ##:: ##. ####: ##::: ##:: ##...:::: ##.. ##:::::: ##:::: ##: ##...::::::: ##::: ##:: ##:::: ##: ##:::: ##:
 ##:::::::: ##:: ##:. ###: ##::: ##:: ##::::::: ##::. ##::::: ##:::: ##: ##:::::::::: ##::: ##:: ##:::: ##: ##:::: ##:
 ##:::::::'####: ##::. ##:. ######::: ########: ##:::. ##::::. #######:: ##::::::::::. ######:::. #######:: ########::
..::::::::....::..::::..:::......::::........::..:::::..::::::.......:::..::::::::::::......:::::.......:::........:::
*/

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../owner/Operator.sol";
import "../elastic/UFragments.sol";

/**
 * @title FogElasticToken
 * @dev An elastic supply token that uses the uFragments mechanism for rebasing, with operator-controlled minting
 *      and owner recovery of unsupported tokens.
 */
contract FogElasticToken is UFragments, Operator {
    using SafeERC20 for IERC20;

    /**
     * @notice Constructor for FogElasticToken.
     * @dev Initializes the token with a name and symbol by calling the UFragments constructor.
     *      The Operator constructor (inherited from Ownable) is automatically invoked.
     * @param _name The name of the token.
     * @param _symbol The symbol of the token.
     */
    constructor(string memory _name, string memory _symbol) UFragments(_name, _symbol) {
        // No additional initialization required.
    }

    /**
     * @notice Mints new tokens (in fragments) to a specified recipient.
     * @dev Can only be called by the operator. The function uses the underlying _mint logic
     *      inherited from UFragments to update balances in terms of gons.
     * @param recipient The address of the recipient.
     * @param amount The amount of tokens (in fragments) to mint.
     * @return success True if the recipient's balance increased after minting.
     */
    function mint(address recipient, uint256 amount) public onlyOperator returns (bool success) {
        uint256 balanceBefore = balanceOf(recipient);
        _mint(recipient, amount);
        uint256 balanceAfter = balanceOf(recipient);
        return balanceAfter > balanceBefore;
    }

    /**
     * @notice Allows the owner to recover any ERC20 tokens that were accidentally sent to this contract.
     * @dev Uses SafeERC20 to safely transfer tokens.
     * @param token The ERC20 token contract to recover.
     * @param amount The amount of tokens to recover.
     * @param to The address that will receive the recovered tokens.
     */
    function governanceRecoverUnsupported(IERC20 token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "FogElasticToken: Cannot transfer to zero address");
        token.safeTransfer(to, amount);
    }
}

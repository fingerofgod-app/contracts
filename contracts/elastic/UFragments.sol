// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "../lib/SafeMathInt.sol";
import "../interfaces/IUFragments.sol";

/**
 * @title uFragments ERC20 token
 * @dev This is part of an implementation of the uFragments Ideal Money protocol.
 *      uFragments is a normal ERC20 token, but its supply can be adjusted by splitting and
 *      combining tokens proportionally across all wallets.
 *
 *      uFragment balances are internally represented with a hidden denomination, 'gons'.
 *      We support splitting the currency in expansion and combining the currency on contraction by
 *      changing the exchange rate between the hidden 'gons' and the public 'fragments'.
 */
abstract contract UFragments is IUFragments, ERC20Burnable, Ownable {
    // PLEASE READ BEFORE CHANGING ANY ACCOUNTING OR MATH
    // Anytime there is division, there is a risk of numerical instability from rounding errors. In
    // order to minimize this risk, we adhere to the following guidelines:
    // 1) The conversion rate adopted is the number of gons that equals 1 fragment.
    //    The inverse rate must not be used--TOTAL_GONS is always the numerator and _totalSupply is
    //    always the denominator. (i.e. If you want to convert gons to fragments instead of
    //    multiplying by the inverse rate, you should divide by the normal rate)
    // 2) Gon balances converted into Fragments are always rounded down (truncated).
    //
    // We make the following guarantees:
    // - If address 'A' transfers x Fragments to address 'B'. A's resulting external balance will
    //   be decreased by precisely x Fragments, and B's external balance will be precisely
    //   increased by x Fragments.
    //
    // We do not guarantee that the sum of all balances equals the result of calling totalSupply().
    // This is because, for any conversion function 'f()' that has non-zero rounding error,
    // f(x0) + f(x1) + ... + f(xn) is not always equal to f(x0 + x1 + ... xn).
    using SafeMathInt for int256;

    event LogRebase(uint256 indexed epoch, uint256 totalSupply);
    event LogMonetaryPolicyUpdated(address monetaryPolicy);

    // Used for authentication
    address public monetaryPolicy;

    modifier onlyMonetaryPolicy() {
        require(msg.sender == monetaryPolicy, "UFragments: caller is not monetary policy");
        _;
    }

    modifier validRecipient(address to) {
        require(to != address(0x0), "UFragments: recipient is zero address");
        require(to != address(this), "UFragments: recipient is token contract");
        _;
    }

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = type(uint256).max;
    uint256 private constant MAX_UINT220 = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffff; // (2^220) - 1 = 1.6849967e+66
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 500_000 * 10 ** DECIMALS;

    // TOTAL_GONS is a multiple of INITIAL_FRAGMENTS_SUPPLY so that _gonsPerFragment is an integer.
    // Use the highest value that fits in a uint256 for max granularity.
    uint256 private constant TOTAL_GONS = MAX_UINT220 - (MAX_UINT220 % INITIAL_FRAGMENTS_SUPPLY); // can support to mint upto 3.3 million billion of tokens

    // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
    uint256 private constant MAX_SUPPLY = type(uint128).max; // (2^128) - 1

    uint256 private _originalTotalSupply; // original supply for recalculations after rebasing
    uint256 private _totalSupply;
    uint256 private _gonsPerFragment;
    mapping(address => uint256) private _gonBalances;

    // This is denominated in Fragments, because the gons-fragments conversion might change before
    // it's fully paid.
    mapping(address => mapping(address => uint256)) private _allowedFragments;

    // EIP-2612: permit – 712-signed approvals
    // https://eips.ethereum.org/EIPS/eip-2612
    string public constant EIP712_REVISION = "1";
    bytes32 public constant EIP712_DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // EIP-2612: keeps track of number of permits per address
    mapping(address => uint256) private _nonces;

    // Total tokens burned
    uint256 public totalBurned;

    /**
     * @param monetaryPolicy_ The address of the monetary policy contract to use for authentication.
     */
    function setMonetaryPolicy(address monetaryPolicy_) external onlyOwner {
        monetaryPolicy = monetaryPolicy_;
        emit LogMonetaryPolicyUpdated(monetaryPolicy_);
    }

    /**
     * @dev Notifies Fragments contract about a new rebase cycle.
     * @param supplyDelta The number of new fragment tokens to add into circulation via expansion.
     * @return The total number of fragments after the supply adjustment.
     */
    function rebase(uint256 epoch, int256 supplyDelta) external override onlyMonetaryPolicy returns (uint256) {
        if (supplyDelta == 0) {
            emit LogRebase(epoch, _totalSupply);
            return _totalSupply;
        }

        if (supplyDelta < 0) {
            _originalTotalSupply -= (uint256(supplyDelta.abs()) * _originalTotalSupply) / _totalSupply;
            _totalSupply -= uint256(supplyDelta.abs());
        } else {
            _originalTotalSupply += (uint256(supplyDelta) * _originalTotalSupply) / _totalSupply;
            _totalSupply += uint256(supplyDelta);
        }

        if (_originalTotalSupply > MAX_SUPPLY) {
            _totalSupply -= (_originalTotalSupply - MAX_SUPPLY);
            _originalTotalSupply = MAX_SUPPLY;
        }

        _gonsPerFragment = TOTAL_GONS / _originalTotalSupply;

        // From this point forward, _gonsPerFragment is taken as the source of truth.
        // We recalculate a new _totalSupply to be in agreement with the _gonsPerFragment
        // conversion rate.
        // This means our applied supplyDelta can deviate from the requested supplyDelta,
        // but this deviation is guaranteed to be < (_totalSupply^2)/(TOTAL_GONS - _totalSupply).
        //
        // In the case of _totalSupply <= MAX_UINT128 (our current supply cap), this
        // deviation is guaranteed to be < 1, so we can omit this step. If the supply cap is
        // ever increased, it must be re-included.
        // _totalSupply = TOTAL_GONS / _gonsPerFragment

        emit LogRebase(epoch, _totalSupply);
        return _totalSupply;
    }

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        _totalSupply = _originalTotalSupply = INITIAL_FRAGMENTS_SUPPLY;

        _gonBalances[msg.sender] = TOTAL_GONS;
        _gonsPerFragment = TOTAL_GONS / _originalTotalSupply;

        emit Transfer(address(0x0), msg.sender, _totalSupply);
    }

    function decimals() public pure override returns (uint8) {
        return uint8(DECIMALS);
    }

    function gonsPerFragment() public view override returns (uint256) {
        return _gonsPerFragment;
    }

    /**
     * @return The total number of fragments.
     */
    function totalSupply() public view override(ERC20, IUFragments) returns (uint256) {
        return _totalSupply;
    }

    function originalTotalSupply() public view returns (uint256) {
        return _originalTotalSupply;
    }

    /**
     * @param who The address to query.
     * @return The balance of the specified address.
     */
    function balanceOf(address who) public view override returns (uint256) {
        return _gonBalances[who] / _gonsPerFragment;
    }

    /**
     * @param who The address to query.
     * @return The gon balance of the specified address.
     */
    function scaledBalanceOf(address who) external view override returns (uint256) {
        return _gonBalances[who];
    }

    /**
     * @return the total number of gons.
     */
    function scaledTotalSupply() external pure override returns (uint256) {
        return TOTAL_GONS;
    }

    /**
     * @return The number of successful permits by the specified address.
     */
    function nonces(address who) public view returns (uint256) {
        return _nonces[who];
    }

    /**
     * @return The computed DOMAIN_SEPARATOR to be used off-chain services
     *         which implement EIP-712.
     *         https://eips.ethereum.org/EIPS/eip-2612
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return keccak256(abi.encode(EIP712_DOMAIN, keccak256(bytes(name())), keccak256(bytes(EIP712_REVISION)), chainId, address(this)));
    }

    /**
     * @dev Transfer all of the sender's wallet balance to a specified address.
     * @param to The address to transfer to.
     * @return True on success, false otherwise.
     */
    function transferAll(address to) external validRecipient(to) returns (bool) {
        uint256 gonValue = _gonBalances[msg.sender];
        uint256 value = gonValue / _gonsPerFragment;

        delete _gonBalances[msg.sender];
        _gonBalances[to] = _gonBalances[to] + gonValue;

        emit Transfer(msg.sender, to, value);
        return true;
    }

    /**
     * @dev Function to check the amount of tokens that an owner has allowed to a spender.
     * @param owner_ The address which owns the funds.
     * @param spender The address which will spend the funds.
     * @return The number of tokens still available for the spender.
     */
    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowedFragments[owner_][spender];
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     * @param value The amount of tokens to be transferred.
     */
    function transferFrom(address from, address to, uint256 value) public override validRecipient(to) returns (bool) {
        _allowedFragments[from][msg.sender] = _allowedFragments[from][msg.sender] - value;

        uint256 gonValue = value * _gonsPerFragment;
        _gonBalances[from] = _gonBalances[from] - gonValue;
        _gonBalances[to] = _gonBalances[to] + gonValue;

        emit Transfer(from, to, value);
        return true;
    }

    /**
     * @dev Transfer all balance tokens from one address to another.
     * @param from The address you want to send tokens from.
     * @param to The address you want to transfer to.
     */
    function transferAllFrom(address from, address to) external validRecipient(to) returns (bool) {
        uint256 gonValue = _gonBalances[from];
        uint256 value = gonValue / _gonsPerFragment;

        _allowedFragments[from][msg.sender] = _allowedFragments[from][msg.sender] - value;

        delete _gonBalances[from];
        _gonBalances[to] = _gonBalances[to] + gonValue;

        emit Transfer(from, to, value);
        return true;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to a spender.
     * This method should be used instead of approve() to avoid the double approval vulnerability
     * described above.
     * @param spender The address which will spend the funds.
     * @param addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _allowedFragments[msg.sender][spender] = _allowedFragments[msg.sender][spender] + addedValue;

        emit Approval(msg.sender, spender, _allowedFragments[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to a spender.
     *
     * @param spender The address which will spend the funds.
     * @param subtractedValue The amount of tokens to decrease the allowance by.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 oldValue = _allowedFragments[msg.sender][spender];
        _allowedFragments[msg.sender][spender] = (subtractedValue >= oldValue) ? 0 : oldValue - subtractedValue;

        emit Approval(msg.sender, spender, _allowedFragments[msg.sender][spender]);
        return true;
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        uint256 currentAllowance = _allowedFragments[owner][spender];
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowedFragments[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal override {
        require(value < MAX_SUPPLY, "UFragments: Transfer amount too large");
        if (from == address(0)) {
            require(to != address(0), "UFragments: Invalid transfer from zero to zero");
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
            require(_totalSupply <= MAX_SUPPLY, "UFragments: Mint amount too large");
            _gonBalances[to] = _gonBalances[to] + value * _gonsPerFragment;
        } else if (to == address(0)) {
            uint256 fromBalance = balanceOf(from);
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            _gonBalances[from] = _gonBalances[from] - value * _gonsPerFragment;
            unchecked {
                // Overflow strictly not possible: value < totalSupply or value <= fromBalance < totalSupply.
                _totalSupply -= value;
                require(_totalSupply > 0, "UFragments: Burn amount too large");
            }
            totalBurned += value;
        } else {
            uint256 gonValue = value * _gonsPerFragment;
            _gonBalances[from] = _gonBalances[from] - gonValue;
            _gonBalances[to] = _gonBalances[to] + gonValue;
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Allows for approvals to be made via secp256k1 signatures.
     * @param owner The owner of the funds
     * @param spender The spender
     * @param value The amount
     * @param deadline The deadline timestamp, type(uint256).max for max deadline
     * @param v Signature param
     * @param s Signature param
     * @param r Signature param
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
        require(block.timestamp <= deadline);

        uint256 ownerNonce = _nonces[owner];
        bytes32 permitDataDigest = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, ownerNonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), permitDataDigest));

        require(owner == ecrecover(digest, v, r, s));

        _nonces[owner] = ownerNonce + 1;

        _allowedFragments[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}

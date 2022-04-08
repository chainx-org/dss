pragma solidity >=0.5.12;

interface VatLike {
    function urns(bytes32, address) external returns (
        uint256 ink,   // Locked Collateral  [wad]
        uint256 art    // Normalised Debt    [wad]
    );
}

interface JugLike {
    function drip(bytes32) external returns (uint256);
}

interface TokenLike {
    function balanceOf(address) external returns (uint256);
    function transfer(address,uint256) external returns (bool);
}

contract Rebate {
    VatLike                  public vat;   // CDP Engine
    JugLike                  public jug;   // Rate Engine
    TokenLike                public gov;   // Governance
    mapping (address => mapping(bytes32 => uint256)) public rates;  // [ray]

    constructor(address vat_,address jug_, address gov_) public {
        vat = VatLike(vat_);
        jug = JugLike(jug_);
        gov = TokenLike(gov_);
    }

    // --- Math ---
    uint256 constant ONE = 10 ** 27;

    function add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x);
    }

    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / ONE;
    }

    // --- Earnings ---
    function earn(bytes32 ilk) external {
        (, uint256 art) = vat.urns(ilk, msg.sender);
        uint256 last = rates[msg.sender][ilk];
        if (last == 0) last = ONE;
        uint256 rate = jug.drip(ilk) - last;
        require(rate > 0, "Rebate/no-more-earnings");
        uint256 wad = rmul(rate, art);
        // TODO: Add reward coefficient
        require(gov.balanceOf(address(this)) > wad, "Rebate/insufficient-gov-balance");
        gov.transfer(msg.sender, wad);
        rates[msg.sender][ilk] = add(last, rate);
    }
}
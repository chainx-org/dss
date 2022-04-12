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
    function mint(address,uint256) external;
}

contract Fate {
    VatLike                  public vat;   // CDP Engine
    JugLike                  public jug;   // Rate Engine
    TokenLike                public gov;   // Governance
    mapping (address => mapping(bytes32 => uint256)) public rates;  // [ray]
    uint256                  public last;  // Last updated timestamp
    uint256                   public alpha; // Reward coefficient

    constructor(address vat_,address jug_, address gov_) public {
        vat = VatLike(vat_);
        jug = JugLike(jug_);
        gov = TokenLike(gov_);
        last = block.timestamp + 3 days;
        alpha = M;
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    uint256 constant M = 247 * 10 ** 25;
    uint256 constant D = 99 * 10 ** 25;

    function add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x);
    }
    
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / RAY;
    }
    // optimized version from dss PR #78
    function rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            switch n case 0 { z := b }
            default {
                switch x case 0 { z := 0 }
                default {
                    switch mod(n, 2) case 0 { z := b } default { z := x }
                    let half := div(b, 2)  // for rounding.
                    for { n := div(n, 2) } n { n := div(n,2) } {
                        let xx := mul(x, x)
                        if shr(128, x) { revert(0,0) }
                        let xxRound := add(xx, half)
                        if lt(xxRound, xx) { revert(0,0) }
                        x := div(xxRound, b)
                        if mod(n,2) {
                            let zx := mul(z, x)
                            if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                            let zxRound := add(zx, half)
                            if lt(zxRound, zx) { revert(0,0) }
                            z := div(zxRound, b)
                        }
                    }
                }
            }
        }
    }

    // reward coefficient
    function destiny() internal {
        uint256 x = block.timestamp - last;
        uint256 step = x / 1 days;
        if (step >= 1) {
            last = last + step * 1 days;
            alpha = rmul(alpha, rpow(D, step, RAY));
        }
    }

    // --- Earnings ---
    function adventure(bytes32 ilk) external {
        (, uint256 art) = vat.urns(ilk, msg.sender);
        uint256 prev = rates[msg.sender][ilk];
        if (prev == 0) prev = RAY;
        uint256 rate = jug.drip(ilk) - prev;
        require(rate > 0, "Rebate/no-more-earnings");
        uint256 wad = rmul(rate, art);
        destiny();
        wad = rmul(alpha, wad);

        gov.mint(msg.sender, wad);
        rates[msg.sender][ilk] = add(prev, rate);
    }
}
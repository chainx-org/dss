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

interface GetCdpsLike {
    function getCdpsAsc(address manager, address guy) external view returns (
        uint[] memory ids, 
        address[] memory urns, 
        bytes32[] memory ilks
    );
}

interface TokenLike {
    function balanceOf(address) external returns (uint256);
    function mint(address,uint256) external;
}

contract Fate {
    VatLike                  public vat;   // CDP Engine
    JugLike                  public jug;   // Rate Engine
    TokenLike                public gov;   // Governance
    GetCdpsLike              public cdps;   // CDPs   
    uint256                  public last;  // Last updated timestamp
    uint256                  public alpha; // Reward coefficient
    address                  public manager; // Cdp manager
    mapping (address => mapping(address => uint256)) public rates;  // [ray]

    constructor(address vat_,address jug_, address gov_, address manager_, address cdps_) public {
        vat = VatLike(vat_);
        jug = JugLike(jug_);
        gov = TokenLike(gov_);
        cdps = GetCdpsLike(cdps_);
        manager = manager_;
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
    function adventure(bytes32 ilk, address urn) internal returns (uint256 wad) {
        (, uint256 art) = vat.urns(ilk, urn);
        uint256 prev = rates[msg.sender][urn];
        if (prev == 0) prev = RAY;
        uint256 rate = jug.drip(ilk) - prev;
        if (rate > 0) {
            wad = rmul(rate, art);
            wad = rmul(alpha, wad);
            rates[msg.sender][urn] = add(prev, rate);
        } else {
            wad = 0;
        }
    }

    function treasure() external {
        uint256 wads;
        (, address[] memory urns, bytes32[] memory ilks) = cdps.getCdpsAsc(manager, msg.sender);
        destiny();
        for (uint i = 0; i < urns.length; i++) {
            wads = wads + adventure(ilks[i], urns[i]);
        }
        gov.mint(msg.sender, wads);
    }
}
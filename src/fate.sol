// SPDX-License-Identifier: AGPL-3.0-or-later

/// fate.sol -- BDA reward mint

// Copyright (C) 2018 ChainX Project Authors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

interface GemLike {
    function mint(address, uint256) external;
}

interface ManagerLike {
    function cdpCan(address, uint256, address) external view returns (uint256);

    function ilks(uint256) external view returns (bytes32);

    function owns(uint256) external view returns (address);

    function urns(uint256) external view returns (address);

    function vat() external view returns (address);

    function count(address) external view returns (uint256);

    function first(address) external view returns (uint256);

    function list(uint256) external view returns (uint256, uint256);
}

interface VatLike {
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);

    function urns(bytes32, address) external view returns (uint256, uint256);
}

interface RegistryLike {
    function proxies(address) external view returns (address);
}

contract Fate {
    // --- Auth ---
    mapping(address => uint256) public wards;

    function rely(address usr) external auth {wards[usr] = 1; emit Rely(usr);}
    function deny(address usr) external auth {wards[usr] = 0; emit Deny(usr);}
    modifier auth {
        require(wards[msg.sender] == 1, "Fate/not-authorized");
        _;
    }

    GemLike  public gem; // BDA contract
    ManagerLike public manager; // CDP Manager
    RegistryLike public registry; // Proxy registry

    // --- Data ---
    uint256 public step = 1 days; // Length of time between price drops [seconds]
    uint256 public cut = 0.99E27;  // Per-step multiplicative factor     [ray]
    uint256 public top = 2.47E27;  // max alpha     [ray]
    uint256 public start; // contract deployment time [seconds]
    uint256 public delay;  // Active Flag [seconds]
    uint256 public live;  // Active Flag

    mapping(uint256 => uint256) public rates;      // CDPId => The rate of the last claim [ray]

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    event File(bytes32 indexed what, uint256 data);

    // --- Init ---
    constructor (address gem_, address manager_, address registry_,uint256 delay_) public {
        wards[msg.sender] = 1;
        start = block.timestamp;
        delay = delay_;
        gem = GemLike(gem_);
        manager = ManagerLike(manager_);
        registry = RegistryLike(registry_);
        live = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if (what == "cut") require((cut = data) <= RAY, "Fate/cut-gt-RAY");
        else if (what == "step") step = data;
        else if (what == "top") top = data;
        else if (what == "start") start = data;
        else if (what == "delay") delay = data;
        else revert("Fate/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / RAY;
    }
    // optimized version from dss PR #78
    function rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            switch n case 0 {z := b}
            default {
                switch x case 0 {z := 0}
                default {
                    switch mod(n, 2) case 0 {z := b} default {z := x}
                    let half := div(b, 2)  // for rounding.
                    for {n := div(n, 2)} n {n := div(n, 2)} {
                        let xx := mul(x, x)
                        if shr(128, x) {revert(0, 0)}
                        let xxRound := add(xx, half)
                        if lt(xxRound, xx) {revert(0, 0)}
                        x := div(xxRound, b)
                        if mod(n, 2) {
                            let zx := mul(z, x)
                            if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {revert(0, 0)}
                            let zxRound := add(zx, half)
                            if lt(zxRound, zx) {revert(0, 0)}
                            z := div(zxRound, b)
                        }
                    }
                }
            }
        }
    }

    // Compute the next alpha value.
    function destiny(uint256 dur) public view returns (uint256){
        return rmul(top, rpow(cut, dur / step, RAY));
    }

    // --- Earnings ---
    function adventure(uint256 cdp) public {
        require(live == 1, "Fate/not-live");
        uint256 dur = sub(block.timestamp, add(start, delay));
        require(dur > 0, "Fate/not-start-up");
        address own = manager.owns(cdp);
        address proxy = registry.proxies(msg.sender);

        require(own == msg.sender || own == proxy || manager.cdpCan(own, cdp, msg.sender) == 1, "Fate/not-own-cdp");

        address vat = manager.vat();
        address urn = manager.urns(cdp);
        bytes32 ilk = manager.ilks(cdp);
        (, uint256 rate,,,) = VatLike(vat).ilks(ilk);
        (, uint256 art) = VatLike(vat).urns(ilk, urn);

        uint256 diff_rate = sub(rate, rates[cdp]);
        require(diff_rate > 0, "Fate/diff-rate-zero");
        uint256 alpha = destiny(dur);
        require(alpha > 0, "Fate/alpha-zero");
        uint256 reward = rmul(alpha, rmul(diff_rate, art));
        require(reward > 0, "Fate/reward-zero");

        gem.mint(msg.sender, reward);
        rates[cdp] = rate;
    }

    function getAllCdp(address guy) public view returns (uint256[] memory ids) {
        uint256 count = manager.count(guy);
        ids = new uint256[](count);
        uint256 i = 0;
        uint256 id = manager.first(guy);

        while (id > 0) {
            ids[i] = id;
            (, id) = manager.list(id);
            i++;
        }
    }

    function treasure(){
        uint[] ids = getAllCdp(msg.sender);
        for (uint i = 0; i < ids.length; i++) {
            adventure(id1s[i]);
        }

        address proxy = registry.proxies(msg.sender);
        ids = getAllCdp(proxy);
        for (uint i = 0; i < ids.length; i++) {
            adventure(ids[i]);
        }
    }

    // --- Shutdown ---
    function cage() external auth {
        live = 0;
    }
}

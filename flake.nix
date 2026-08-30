{
  description = "Scripts for automatically decoding Domesday LaserDisc images through ld-decode";

  inputs = {
    # ld-decode is itself a flake; pinned to the parallel-decode branch.
    ld-decode.url = "github:happycube/ld-decode/chad-2026.07.04-prev8-parallel";

    # Take nixpkgs from ld-decode rather than pinning a second copy, so the
    # tools in the dev shell are the same builds ld-decode itself was tested
    # and wrapped against.
    nixpkgs.follows = "ld-decode/nixpkgs";
    flake-utils.follows = "ld-decode/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ld-decode }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        lddecode = ld-decode.packages.${system}.ld-decode;

        # Everything the decode scripts shell out to. ld-decode wraps its own
        # copies of ffmpeg and flac onto its PATH; these are here so the
        # scripts in this repo can call them directly too.
        decodeTools = [
          lddecode
          pkgs.ffmpeg
          pkgs.flac
        ];
      in
      {
        packages = {
          ld-decode = lddecode;
          default = lddecode;
        };

        apps.default = {
          type = "app";
          program = "${lddecode}/bin/ld-decode";
        };

        devShells.default = pkgs.mkShell {
          packages = decodeTools ++ [
            pkgs.shellcheck
          ];

          shellHook = ''
            echo "domesday-decode-script environment"
            echo "  ld-decode $(ld-decode --version 2>/dev/null || echo '(not found)')"
          '';
        };
      }
    );
}

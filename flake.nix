{
  description = "Scripts for automatically decoding Domesday LaserDisc images through ld-decode";

  inputs = {
    # ld-decode is itself a flake; pinned to upstream's rev8 development branch.
    ld-decode.url = "github:happycube/ld-decode/8.0.0dev";

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

        # The decode scripts are bash 4+ (associative arrays, ${var,,}, wait -n)
        # and call coreutils with GNU options (date -Is). macOS ships bash 3.2
        # and BSD coreutils in /bin, so both are named here rather than left to
        # whatever the stdenv happens to put on PATH ahead of the system ones.
        #
        # git is here for the same reason from the other direction: on macOS
        # /usr/bin/git is a stub that execs whatever DEVELOPER_DIR points at,
        # and the stdenv sets DEVELOPER_DIR to a Nix apple-sdk that holds no
        # git -- so the stub fails with "tool 'git' not found" inside the
        # shell. A real git on PATH ahead of it settles that.
        shellTools = [
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.git
          pkgs.jq
          pkgs.shellcheck
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
          packages = decodeTools ++ shellTools;

          shellHook = ''
            echo "domesday-decode-script environment"
            echo "  ld-decode $(ld-decode --version 2>/dev/null || echo '(not found)')"
          '';
        };
      }
    );
}

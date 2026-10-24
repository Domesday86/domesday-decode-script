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

    # decode-orc (orc-cli) maps, aligns and stacks the decodes into the video
    # and writes the per-set EFM images; vfs-verifier supplies vfs-stacker
    # and vfs-verifier for the VFS image. Both are pinned at whatever main
    # was when flake.lock was last updated. Each keeps its own nixpkgs: they
    # are built and tested against those, and nothing here links against
    # them, so sharing one would save closure size at the cost of building
    # them against a nixpkgs neither project has tried.
    decode-orc = {
      url = "github:simoninns/decode-orc";
      inputs.flake-utils.follows = "ld-decode/flake-utils";
    };
    vfs-verifier = {
      url = "github:Domesday86/vfs-verifier";
      inputs.flake-utils.follows = "ld-decode/flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, ld-decode, decode-orc, vfs-verifier }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        lddecode = ld-decode.packages.${system}.ld-decode;
        # decode-orc as pinned, plus the fixes in patches/decode-orc-*.patch
        # that it does not have yet. Each patch says why; each goes once the
        # pinned revision has its fix. The patches are part of every decode-orc
        # stage's stamp (lib/stage.sh), so changing one rebuilds those stages.
        decodeorc = decode-orc.packages.${system}.decode-orc.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/decode-orc-efm-sync.patch
          ];
        });
        vfstools = vfs-verifier.packages.${system}.vfs-tools;

        # Everything the decode scripts shell out to. ld-decode wraps its own
        # copies of ffmpeg and flac onto its PATH; these are here so the
        # scripts in this repo can call them directly too.
        decodeTools = [
          lddecode
          pkgs.ffmpeg
          pkgs.flac
        ];

        # The pack stages: orc-cli (decode-orc ships it beside orc-gui),
        # vfs-stacker and vfs-verifier, and sqlite and yq for reading the
        # .meta databases and the disc metadata YAML.
        packTools = [
          decodeorc
          vfstools
          pkgs.sqlite
          pkgs.yq-go
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
          decode-orc = decodeorc;
          vfs-tools = vfstools;
          default = lddecode;
        };

        apps.default = {
          type = "app";
          program = "${lddecode}/bin/ld-decode";
        };

        devShells.default = pkgs.mkShell {
          packages = decodeTools ++ packTools ++ shellTools;

          shellHook = ''
            echo "domesday-decode-script environment"
            echo "  ld-decode    $(ld-decode --version 2>/dev/null || echo '(not found)')"
            echo "  orc-cli      decode-orc ${decode-orc.shortRev or "(dirty)"}"
            echo "  vfs-stacker  vfs-verifier ${vfs-verifier.shortRev or "(dirty)"}"
          '';
        };
      }
    );
}

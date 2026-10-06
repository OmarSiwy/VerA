{
  description = "VerA";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # x86_64-darwin only: nixpkgs 26.11 dropped it, and 26.05 still builds
    # and caches it (security fixes until the end of 2026). Fetched only when
    # an x86_64-darwin output is evaluated.
    nixpkgs-x86_64-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-x86_64-darwin,
      flake-utils,
      zig-overlay,
    }:
    let
      lib = nixpkgs.lib;

      # The release binaries, by version (tools/update-sources.py writes it;
      # publish.yaml reruns it after every release).
      sources = lib.importJSON ./sources.json;
      latest = lib.last (lib.sort lib.versionOlder (lib.attrNames sources));

      # `vera` builds every device by spawning `zig` on code it generated for
      # one Zig release, so it is wrapped with that Zig first on PATH. It reads
      # nothing else at run time: the contract and the `sim` tree are embedded
      # (build.zig `sim_sources`) and written under the work directory.
      wrapZig = zig: ''
        wrapProgram $out/bin/vera --prefix PATH : ${zig}/bin
      '';

      # From source. ReleaseFast, what publish.yaml ships: the compiler is a
      # batch tool whose safety checks the test suites already exercise in
      # Debug, and the source and binary packages should be the same program.
      fromSource =
        {
          lib,
          stdenv,
          makeWrapper,
          zig,
          # `zig build -j`: parallel build steps. 2 keeps a build in a few GB;
          # `.override { zigJobs = 8; }` on a machine with the memory for it.
          zigJobs ? 2,
        }:
        stdenv.mkDerivation (
          {
            pname = "vera";
            version = "${latest}-unstable-${builtins.substring 0 8 (self.lastModifiedDate or "19700101")}";
            # Only what `zig build install` reads: docs/ and tests/ are 33 MB
            # that would rebuild the package on every fixture edit.
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./build.zig
                ./build.zig.zon
                ./lib
                ./src
                ./tools
              ];
            };
            nativeBuildInputs = [
              zig
              makeWrapper
            ];
            dontConfigure = true;
            dontBuild = true;
            # -Dcpu=baseline: the default is the build machine's CPU, and a
            # substituted binary must run on any CPU of the system.
            installPhase = ''
              runHook preInstall
              # The environment, not --global-cache-dir: the build runner's own
              # children read it, and $HOME does not exist in the sandbox.
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
              zig build install -j${toString zigJobs} \
                -Doptimize=ReleaseFast -Dcpu=baseline --prefix "$out"
              ${wrapZig zig}
              runHook postInstall
            '';
            meta = {
              description = "Verilog-AMS compiler: Verilog-A to Zig device code";
              homepage = "https://github.com/OmarSiwy/VerA";
              license = lib.licenses.asl20;
              mainProgram = "vera";
            };
          }
          # Zig's linker signs the Mach-O ad hoc; strip would void it. Unproven
          # on a Mac here, so left as the release package does it.
          // lib.optionalAttrs stdenv.hostPlatform.isDarwin { dontStrip = true; }
        );

      # A release binary (sources.json). Statically linked on Linux, so
      # nothing to patch; not stripped, so the Darwin ad-hoc signature holds.
      fromRelease =
        {
          lib,
          stdenvNoCC,
          fetchurl,
          makeWrapper,
          zig,
          version,
          source,
          contract,
        }:
        stdenvNoCC.mkDerivation {
          pname = "vera";
          inherit version;
          src = fetchurl { inherit (source) url sha256; };
          sourceRoot = ".";
          nativeBuildInputs = [ makeWrapper ];
          dontStrip = true;
          installPhase = ''
            install -Dm755 vera $out/bin/vera
            # The tarball is the binary alone; the ABI file is the tag's.
            install -Dm644 ${fetchurl { inherit (contract) url sha256; }} $out/share/vera/contract.zig
            ${wrapZig zig}
          '';
          meta = {
            description = "Verilog-AMS compiler: Verilog-A to Zig device code (release binary)";
            homepage = "https://github.com/OmarSiwy/VerA";
            license = lib.licenses.asl20;
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
            mainProgram = "vera";
          };
        };

      # zig-overlay's packages, built from `pkgs` rather than its own nixpkgs,
      # so the overlay works on whatever nixpkgs the consumer has.
      zigsFor =
        pkgs:
        import "${zig-overlay}/default.nix" {
          inherit pkgs;
          system = pkgs.stdenv.hostPlatform.system;
          nixpkgs = pkgs.path;
        };

      # pkgs -> { vera; veraPackages.<version> and .latest }, for the
      # overlay and for `packages`.
      veraFor =
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          zigs = zigsFor pkgs;
          releases = lib.mapAttrs (
            version: s:
            pkgs.callPackage fromRelease {
              inherit version;
              zig = zigs.${s.zig};
              source = s.${system};
              inherit (s) contract;
            }
          ) (lib.filterAttrs (_: s: s ? ${system}) sources);
        in
        {
          vera = pkgs.callPackage fromSource { zig = zigs."0.17.0"; };
          veraPackages =
            releases // lib.optionalAttrs (releases ? ${latest}) { latest = releases.${latest}; };
        };

      # `vera --help` runs, and a resistor goes through codegen and through
      # `zig` type-checking it against the contract, offline in the sandbox.
      smoke =
        pkgs: vera:
        pkgs.runCommand "vera-smoke-${vera.version}" { nativeBuildInputs = [ vera ]; } ''
          # What README "Install with Nix" tells a derivation to set: no $HOME.
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          vera --help > /dev/null
          test -s ${vera}/share/vera/contract.zig
          cat > r.va <<'EOF'
          module r(p, n);
            inout p, n;
            electrical p, n;
            parameter real R = 1k;
            analog I(p, n) <+ V(p, n) / R;
          endmodule
          EOF
          vera --emit-zig r.va > r.zig
          grep -q . r.zig
          vera --check r.va
          touch $out
        '';
    in
    {
      overlays.default = final: _prev: veraFor final;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import (if system == "x86_64-darwin" then nixpkgs-x86_64-darwin else nixpkgs) {
          inherit system;
          config.allowUnfree = true;
          # 26.05's "last release for x86_64-darwin" warning, on every
          # evaluation; a no-op on nixpkgs-unstable.
          config.allowDeprecatedx86_64Darwin = true;
        };

        built = veraFor pkgs;

        zig = (zigsFor pkgs)."0.17.0";
        commonInputs = [
          zig
        ];

        # A shell carries what nixpkgs builds for this system (Xyce and perf
        # are not on Darwin, iverilog not on 26.05's x86_64-darwin).
        available = lib.filter (lib.meta.availableOn pkgs.stdenv.hostPlatform);

        # GPU Toolchains: CUDA on Linux, ROCm on x86_64-linux. Gated by hand,
        # since `available` sees only the top package, not its dependencies.
        cudaPkgs = lib.optionals pkgs.stdenv.hostPlatform.isLinux (
          with pkgs.cudaPackages;
          [
            cudatoolkit # nvcc, headers, libs, nvidia-smi
            cuda_cudart # runtime (libcudart)
            cuda_nvcc # compiler driver
          ]
        );
        rocmPkgs = lib.optionals (system == "x86_64-linux") (
          with pkgs.rocmPackages;
          [
            clr # HIP runtime (libamdhip64)
            hipcc # HIP compiler
            rocminfo # device query
            rocm-smi # GPU monitoring
            hip-common # headers
          ]
        );
        # OpenVAF-Reloaded is not in nixpkgs: its release binary, linked against
        # the LLVM 18 it was built with. The reference Verilog-A compiler the
        # external accuracy suites compare VerA against (tests/fixtures/external/).
        openvaf = pkgs.stdenv.mkDerivation rec {
          pname = "openvaf-reloaded";
          version = "24.0.2mob";
          src = pkgs.fetchurl {
            url = "https://github.com/OpenVAF/OpenVAF-Reloaded/releases/download/v${version}/openvaf-r-v${version}-linux-x86_64.tar.gz";
            hash = "sha256-sSt7FybRA+GMJYjDofkfhHXPA9+KO94U2Rl5fSIeMRA=";
          };
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [
            pkgs.llvmPackages_18.libllvm
            pkgs.stdenv.cc.cc.lib
          ];
          installPhase = ''
            install -Dm755 bin/openvaf-r $out/bin/openvaf-r
            ln -s openvaf-r $out/bin/openvaf
          '';
        };

        # The tools VerA's results are checked against, by name.
        referenceTools =
          available [
            pkgs.iverilog # IEEE 1364 simulation reference (ivtest, sv-tests)
            pkgs.verilator # lint / parse reference
            pkgs.yosys # parse / elaborate reference
            pkgs.ngspice # OSDI host: VerA's .osdi vs OpenVAF's, same deck
            pkgs.xyce # second analog simulator
            pkgs.gnucap # third opinion for disagreements
            pkgs.python3 # harness scripts
          ]
          ++ pkgs.lib.optional (system == "x86_64-linux") openvaf;

        gpuLibPath = pkgs.lib.makeLibraryPath (
          [
            "/run/opengl-driver" # NixOS NVIDIA driver (libcuda.so.1)
          ]
          ++ cudaPkgs
          ++ rocmPkgs
        );
      in
      {
        devShells.default = pkgs.mkShell ({
          packages =
            commonInputs
            ++ available [
              pkgs.llvmPackages_21.llvm # needed for nvptx compilation
              pkgs.iverilog # zig build test-beh-verilog
              pkgs.verilator
            ]
            ++ cudaPkgs
            ++ rocmPkgs;
          LD_LIBRARY_PATH = gpuLibPath;
        });

        devShells.benchmarking = pkgs.mkShell ({
          packages =
            commonInputs
            ++ available [
              pkgs.llvmPackages_21.llvm

              # Visualize performance
              pkgs.perf
              pkgs.flamegraph
              pkgs.inferno
            ]
            ++ referenceTools
            ++ cudaPkgs
            ++ rocmPkgs;
          LD_LIBRARY_PATH = gpuLibPath;
        });

        # The user documentation (docs/): `mdbook build docs`, and
        # tools/doctest.py re-running every transcript a page shows.
        devShells.docs = pkgs.mkShell {
          packages = commonInputs ++ [
            pkgs.mdbook
            pkgs.python3
            pkgs.nodejs # the in-browser runner's smoke test (docs/runner/)
          ];
        };

        packages = built.veraPackages // {
          default = built.vera;
          vera = built.vera;
        };

        apps.default = {
          type = "app";
          program = lib.getExe built.vera;
          meta.description = "Run vera, built from this tree";
        };

        checks = {
          vera = built.vera;
          smoke = smoke pkgs built.vera;
        }
        // lib.optionalAttrs (built.veraPackages ? latest) {
          release = built.veraPackages.latest;
          release-smoke = smoke pkgs built.veraPackages.latest;
        };

        formatter = pkgs.nixfmt;
      }
    );
}

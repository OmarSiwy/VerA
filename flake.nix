{
  description = "VerA";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        zig = zig-overlay.packages.${system}."0.17.0";
        commonInputs = [
          zig
        ];

        # GPU Toolchains
        cudaPkgs = with pkgs.cudaPackages; [
          cudatoolkit # nvcc, headers, libs, nvidia-smi
          cuda_cudart # runtime (libcudart)
          cuda_nvcc # compiler driver
        ];
        rocmPkgs = with pkgs.rocmPackages; [
          clr # HIP runtime (libamdhip64)
          hipcc # HIP compiler
          rocminfo # device query
          rocm-smi # GPU monitoring
          hip-common # headers
        ];
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
          buildInputs = [ pkgs.llvmPackages_18.libllvm pkgs.stdenv.cc.cc.lib ];
          installPhase = ''
            install -Dm755 bin/openvaf-r $out/bin/openvaf-r
            ln -s openvaf-r $out/bin/openvaf
          '';
        };

        # The tools VerA's results are checked against, by name.
        referenceTools = [
          pkgs.iverilog # IEEE 1364 simulation reference (ivtest, sv-tests)
          pkgs.verilator # lint / parse reference
          pkgs.yosys # parse / elaborate reference
          pkgs.ngspice # OSDI host: VerA's .osdi vs OpenVAF's, same deck
          pkgs.xyce # second analog simulator
          pkgs.gnucap # third opinion for disagreements
          pkgs.python3 # harness scripts
        ] ++ pkgs.lib.optional (system == "x86_64-linux") openvaf;

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
            ++ [
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
            ++ [
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

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "vera";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = [
            zig
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            zig build \
              -Doptimize=ReleaseSafe \
              --cache-dir .zig-cache \
              --global-cache-dir "$TMPDIR/zig-global-cache"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            zig build install \
              -Doptimize=ReleaseSafe \
              --prefix "$out" \
              --cache-dir .zig-cache \
              --global-cache-dir "$TMPDIR/zig-global-cache"

            runHook postInstall
          '';
        };
      }
    );
}

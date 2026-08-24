# Why a device contract, not OSDI

This part of the book is for people writing a circuit simulator, or adding
compact-model support to one. It explains how to run VerA's devices inside
your own solver.

The established way to load compiled Verilog-A models is
[OSDI](https://openvaf.semimod.de/docs/details/osdi/), the C interface of
OpenVAF's output: a shared object exporting a descriptor table (parameters,
nodes, Jacobian entries) and function pointers the simulator calls per
instance per iteration. VerA can produce that too ([OSDI
interoperability](osdi.md)). Its native form is different: the generated
device is **Zig source** that your simulator compiles into itself, against a
contract that is one Zig file, `tools/contract.zig`. This page says what that
buys and what it costs, so you can choose.

## What the contract gives a host

**You choose the arithmetic.** Every entry point is generic over a *scalar
family* your host passes at compile time ([scalar families](families.md)).
The family decides how a value carries its derivatives: `f64` or `f32`
derivative lanes, a dense array or exactly the lanes each row needs, one
operating point or a SIMD vector of them. The device publishes which
unknowns need a lane at all (`deriv_reads`) and the exact constant partials
of the rest (`jac_const`), so the family carries no lane the model never
reads.

**The Jacobian is the residual's.** Derivatives propagate through the same
arithmetic that computes the residual (forward-mode automatic
differentiation), so one evaluation returns both, and they cannot disagree.
OpenVAF's output is also exact; the difference is that here the derivative
arithmetic runs in your family, inlined into your loop.

**No indirect call per evaluation.** The device's `eval` is instantiated and
inlined at compile time. There is no descriptor to walk and no function
pointer per instance per iterate, and the compiler optimises the model
together with your stamping code.

**Plain data.** `Model` and `Instance` are structs of value fields with
defaults; the state a device carries across accepted points is a separate
`State`. You allocate them, in whatever layout your solver wants (arrays of
instances, one `Model` row shared by many).

**Many points per call.** A device that declares `batch_ok` evaluates a
vector of operating points exactly, point for point, through the same
generic code ([batching](batching.md)).

**GPUs from the same file.** The device imports only `std` and the contract
and calls no OS; its transcendental functions come from the contract's own
`gm`. The same `device.zig` compiles for NVPTX and AMDGCN
([linking](linking.md)).

**Mistakes fail the build.** `contract.validate` checks the device's every
declaration at compile time, and `contract.validateHost` checks your host
against what the device needs (it calls `setup`, it supplies the VPI
binding, it adds frequency-dependent partials back), when you opt in.

## What OSDI gives that the contract does not

Be clear about these before choosing the contract:

- **Any language.** OSDI is a C ABI: a simulator in C, C++, Rust or Fortran
  loads a `.osdi` file with `dlopen`. The contract is Zig source. A host in
  another language needs a Zig `dyn` module that exports the C functions it
  wants ([linking](linking.md)), and so a Zig toolchain in its build.
- **A stable binary format.** An `.osdi` built once loads into any simulator
  that speaks that OSDI version. A VerA device is regenerated whenever the
  contract's `abi_version` changes (it is 6 at the time of writing), and is
  compiled by the Zig release VerA targets (0.17.0).
- **Simulators that already support it.** ngspice loads OSDI today
  (`pre_osdi`), and so do the flows built around OpenVAF. A simulator that
  speaks OSDI gets VerA's models through `vera --emit-osdi` without code
  changes ([OSDI interoperability](osdi.md); not on `main` yet).
- **Separate compilation.** An OSDI model is compiled once, ahead of time.
  A contract device is compiled with your host, so a large model (BSIM4,
  PSP) adds its compile time to your build, especially in a release build
  through LLVM.

## What adopting it costs

A host in Zig, or a Zig shim in your build; a compile step per device (VerA,
then Zig); a matching contract file (`share/vera/contract.zig` from the same
VerA); and the hooks your devices need, which this part documents one at a
time. The [minimal host](minimal-host.md) is under 100 lines and is the place
to start.

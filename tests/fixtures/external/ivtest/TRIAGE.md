# ivtest: triage

Every disagreement `tools/external_digital.py` reports for this suite, one row
per root cause. A row lists the exact names it covers (fnmatch patterns; a
name's `[`, `]`, `*`, `?` are bracket-escaped), so a new disagreement is never
swallowed by an old row, and a name that stops disagreeing turns its pattern
`STALE`: delete it, and the row with its last pattern.

Verdicts, judged by IEEE 1364-2005 (the Verilog-AMS LRM for VerA's AMS
fixtures), never by either tool's say-so:

- `vera-bug`: VerA is wrong (output, a hang, accepting an error, refusing legal source by a rule the standard does not have).
- `vera-unimplemented`: legal 1364-2005 VerA refuses with a diagnostic that says it is not implemented.
- `vera-correct`: VerA follows the standard; the reference (iverilog, its gold file, the test's expectation) does not.
- `implementation-defined`: both behaviours conform; the cited clause leaves the choice open.
- `out-of-scope`: not a 1364-2005 question (SystemVerilog, Verilog-AMS, SDF files, an Icarus-only behaviour).
- `flaky`: nondeterministic; the reason says what varies.

Measured against `vera` at 05438e97 on 2026-10-20 (230 disagreements).

| names | verdict | reason |
|---|---|---|
| `delay_var` | vera-bug | A.3.1/A.2.2.3: delay2 ::= # delay_value, delay_value may be an identifier; VerA reads `buf #d (g, in);` as a call d(g, in) and refuses (E0207), should take #d then the terminals |
| `fread` | vera-bug | Annex B/§19.11: 1364-2005 reserves none of string, connect, sqrt; under --std=1364-2005 VerA still treats them as Verilog-AMS keywords in some positions (localparam/statement/instance) and refuses |
| `queue_stat` | vera-bug | §10.2.1/§10.4.1 non-ANSI task/function ports may be typed by a following declaration (`input x; integer x;`, `output [7:0] e; reg [7:0] e;`), as §12.3.3 allows for modules. VerA refuses it as a duplicate variable |
| `automatic_error3` | vera-bug | §10.2.3: automatic task variables shall not be NBA targets, nor read by force/assign RHS or an NBA intra-assignment event control; VerA refuses them as assign/force targets but accepts these four uses |
| `automatic_task3` `recursive_task` | vera-bug | §10.2.3: each concurrent or recursive activation of an automatic task has its own variables; VerA lets @f / @(array[j]) inside one activation see another activation's changes (spurious x lines, missing ones) |
| `constfunc10` `constfunc9` | vera-bug | §10.3.5 constant functions: disable of the function's named block inside while(1)/forever must end the call at elaboration; VerA hangs (deterministic, >30 s), while the same function called at run time returns |
| `tri2` | vera-bug | §12.3.6/§12.3.9 an inout port connects to any net expression (bit-select, part-select, concatenation). VerA refuses as 'must name one whole net' (no bidirectional bit bridge); it should connect the selected bits |
| `br_gh127b` `br_gh127c` `br_gh127d` `br_gh127e` `br_gh127f` `pr1866215` `pr2121536` `pr2121536b` `pr2224949` | vera-bug | §12.3.8 ports of different widths connect (truncate or extend, a warning at most); VerA applies the VAMS §6.5.7.1 equal-size rule under --std=1364-2005 and refuses |
| `pr1755629` | vera-bug | §12.4.1: a genvar inside its loop generate block is a constant (a localparam), so target[i].val / U[(i+1)%4].x is a constant hierarchical index (A.9.3); VerA refuses it (E0231) |
| `pr1985582` | vera-bug | §17.1.1.2/§17.3.2: %t of a real time value ($realtime 0.6 in 1ns/1ps) must print 600 in the default unit; VerA rounds the real to the module unit first and prints 1000 |
| `macro_comment_multiline` | vera-bug | §19.3.1: a newline preceded by a backslash continues macro text, a // comment in it is dropped; VerA ends the macro at a backslash-newline inside a // or /* */ comment and parses the rest as module items |
| `localparam_type` `parameter_type` | vera-bug | §4.10.1/§4.8: a time-typed parameter or localparam is unsigned 64-bit; VerA treats it as signed integer (localparam time t = -1 prints -1, t == a time variable holding -1 is 0); should be 18446744073709551615 |
| `pr2913404` | vera-bug | §4.8.2: real/integer conversion rounds to the nearest integer for any width; VerA gives x converting a real of magnitude 2**63 to a 64-bit reg and 0 for every 65-bit conversion either way |
| `pr2728032` `real_delay` `rise_fall_decay1` `rise_fall_delay1` `rise_fall_delay2` `rise_fall_delay3` `verify_two_var_delays` | vera-bug | §6.1.3/§7.14 delay3/delay2 take mintypmax_expression (A.2.2.3), not constant ones: VerA refuses a variable/net delay on a continuous assign, net or gate as non-constant; it should evaluate it when scheduling |
| `pr3296466d` | vera-bug | §7.1.5/§7.1.6 an array of tran instances takes vector terminals, one bit per instance; VerA refuses `tran t[1:0](a, b)` citing §7.6 scalar terminals; it should split the vectors |
| `br_gh1122` | vera-bug | §7.11 strength reduction: a MOS or tran switch whose data terminal is a supply0 net must pass a strong 0; VerA passes z (nmos(o, vss, 1) reads z), so switch-level networks float |
| `br_gh732` | vera-bug | §9.7.1/§19.8: a real-valued parameter or specparam delay (#Delay with Delay = 0.1 in 1ns/1ps) must be 100ps; VerA rounds it to the time unit (0), while a literal #0.1 works |
| `task_nonansi_fail2` `task_nonansi_fail3` `task_nonansi_fail4` `task_nonansi_fail6` `task_nonansi_fail7` `task_nonansi_fail9` `task_nonansi_integer_fail` `task_nonansi_real_fail` `task_nonansi_time_fail` `task_nonansi_vec_fail1` `task_nonansi_vec_fail2` `task_nonansi_vec_fail3` `task_port_range_mismatch` | vera-bug | §10.2.1 non-ANSI task ports completed by a later declaration follow §12.3.3's rules, which VerA now enforces for modules: a port whose declaration carries a type, a second `reg x;`, or a redeclaration whose range or type differs (input [7:0] x vs reg [3:0] x, [3:0] vs real, real vs output integer) is an error; VerA accepts all of these in a task and runs, and should refuse them |
| `pr2219441` | vera-unimplemented | §12.1.2 a constant or an inout net connected across an instance array is legal; VerA refuses it as not done 'by digital execution' |
| `pr1704726b` `pr2350934` `pr2350934b` `pr2350988` | vera-unimplemented | §12.4/A.1.4: a task or function declaration is a module_or_generate_item_declaration, legal in a generate block; VerA refuses it (E0235, not supported) |
| `fscanf_u` `fscanf_u_warn` `fscanf_z` `fscanf_z_warn` | vera-unimplemented | §17.1.1.2 %u/%z (unformatted 2-/4-value data) are 1364-2005 format specifications; VerA's digital engine refuses them as not implemented |
| `fmonitor1` `fmonitor2` | vera-unimplemented | §17.2.2 $fmonitor and $fstrobe are 1364-2005 file output tasks; VerA's digital engine refuses them as not implemented |
| `rise_fall_decay2` | vera-unimplemented | §7.8 pull gates and §7.1 MOS gates on a bit-select output (pullup(bus[0]), nmos(o[1],...)) are legal; VerA refuses as 'only whole-variable lvalues are implemented' (rise_fall_decay2 also has variable delays) |
| `array_lval_select6` `br1029a` `br1029b` `mem1` `pr1033` `pr1661640` `pr1699519` `pr1799904` `pr2014673` `pr245` `pr245_std` `pr273` `pr492` `prng` `string13` | vera-correct | %x/%X is not a 1364-2005 §17.1.1.2 format specification (IEEE 1800 added it as %h); VerA refuses it, iverilog accepts the SystemVerilog alias |
| `decl_before_use1` `decl_before_use5` `pr1909940` `pr1909940b` | vera-correct | 1364-2005 has no general declare-before-use rule (only §9.7.3 events and §4.10.3 specparams, which VerA enforces); a reg, localparam or later implicit net referenced earlier is legal (IEEE 1800 adds the rule) |
| `decl_before_use6` | vera-correct | A.1.4: there is no null module item, so `endtask;` leaves a stray `;` in the module; iverilog, Verilator and yosys accept it leniently |
| `event_array` | vera-correct | A.2.1.3 allows dimensions on an event_identifier, so event arrays are legal 1364-2005; iverilog says 'sorry: event arrays are not supported' (its own limitation), VerA runs the test and prints PASSED |
| `pr1787423` `pr1787423b` `pr2834340` `pr2834340b` | vera-correct | A.3.1: pull_gate_instance has exactly one output_terminal; pulldown (a, b) and pullup (weak1) pu (a, b) are illegal, iverilog accepts them (Verilator and yosys refuse) |
| `pr3194155` | vera-correct | A.4.1.1: a module instance's parameter_value_assignment is #( ... ); `foo #1 bar(...)` is the UDP/gate delay form, illegal on a module, iverilog accepts it |
| `pr1716276` | vera-correct | A.4.1.1: ordered_parameter_assignment ::= expression, so #( , 4) with an empty slot is illegal (Verilator and yosys refuse too) |
| `pr1877743` | vera-correct | A.7.2: a parallel path (=>) has one input and one output descriptor; (a, b, ci => co) needs *>, iverilog accepts the list |
| `timing_check_delayed_signals` `timing_check_syntax` | vera-correct | A.7.5.2: timing_check_limit ::= expression; a bare 0:0:0 is a mintypmax_expression, legal only parenthesised (A.8.4), iverilog accepts it |
| `pr478` | vera-correct | `protect is not a 1364-2005 directive (§19 lists them; Annex E's informative ones exclude it), so it is an undefined macro; iverilog ignores it as a Verilog-XL leftover |
| `always3.1.1B` `always3.1.2A` `always3.1.2B` `always3.1.3A` `always3.1.3B` `always3.1.3C` | vera-correct | an always with no timing control is a zero-delay loop (§9.9.2 calls it a deadlock), not a compile error; iverilog refuses it at elaboration, VerA runs the initial first (§11.4 leaves the order open) and finishes |
| `scope2b` | vera-correct | ivtest lists it CE, but §4.5 makes the undeclared `q` on a continuous-assignment LHS an implicit net (the test's own comment says so); VerA and iverilog both accept and print PASSED |
| `pr1077` | vera-correct | pr1077 is listed -g2 (run as --std=1364-2001) yet selects `begin_keywords "1364-2005"; a 1364-2001 tool has no 2005 keyword set (§19.11 is new in 2005) |
| `param_test3` | vera-correct | §12.2.2.1 an ordered parameter list follows the declaration order, so a value with no parameter left to take it has no meaning; VerA refuses #(1,2,3) on a module with none, iverilog only warns |
| `module_output_port_var2` | vera-correct | §12.3 (A.1.3): `module test;` has no list of ports, so `output reg a;` declares a port the module does not have; Verilator and yosys refuse too |
| `br988` `pr2257003` `pr2257003b` | vera-correct | §12.4/A.4.2 (2005): a generate_block is only the body of a loop or conditional generate; the standalone `begin : a ... end` generate item was 1364-2001's and was removed |
| `pr1938138` | vera-correct | §13.2.1.1: a later same-named module replaces the earlier with a warning (VD-009); VerA warns W1152 and binds the later `a`, iverilog refuses the duplicate |
| `multi_bit_strength` | vera-correct | §17.1.1.5 %v displays the strength of a scalar net; the test expects iverilog's underscore-joined per-bit strengths for a 4-bit net, which 1364 does not define |
| `br_gh827` `pr1804877` `string4` `string5` `string7` `test_width` | vera-correct | §17.1.1.7: under %s leading zeros are never printed; iverilog (and its gold) prints each leading zero byte of a wider reg as a space, VerA prints none |
| `br916a` `br916b` `pr1830834` | vera-correct | §17.1.3: $strobe/$monitor take expression arguments; iverilog prints a SORRY limitation (recorded in its gold) instead of the values VerA prints |
| `pr690` `pr704` `readmem-error` | vera-correct | §17.2.9 Syntax 17-7 gives $readmem's file name as a quoted string and no variable form; VerA reads it literally, iverilog takes any string expression as IEEE 1800 does (moderate confidence) |
| `pr1701855b` | vera-correct | §17.3.1 $printtimescale reports a module's time scale and takes a module path; dummy.ipval is a parameter. VerA refuses, iverilog takes any object |
| `array_word_check` | vera-correct | §18.1.2 Syntax 18-2 $dumpvars takes module or variable identifiers; a memory word array[0] is neither (1364 VCD dumps no arrays). VerA refuses, iverilog dumps the word as an extension |
| `pr2994193` | vera-correct | §18.1.2 every $dumpvars call shall execute at the same simulation time; the test calls it again at a later clock. VerA refuses, vvp warns and ignores it |
| `undef` | vera-correct | §19.3.2: an `undef'd macro is as if never defined, and a never-defined `name has no meaning (§19.3.1); iverilog expands it to nothing with a warning (Verilator and yosys refuse too) |
| `pr3012758` | vera-correct | §19.5 Syntax 19-6 is `include "filename"; a macro as the file name is IEEE 1800 §22.4's addition, so VerA refuses `include `TESTFILE |
| `pr1403406` `pr434` `resetall` | vera-correct | §19.8 it is an error if some modules have a `timescale and others do not; each test leaves modules without one (or after `resetall). VerA refuses, iverilog defaults them |
| `no_timescale_in_module` | vera-correct | §19.8 places no outside-a-module restriction on `timescale (unlike §19.2 `default_nettype and §19.6 `resetall, which VerA refuses inside a module); iverilog's refusal is its own rule |
| `comment1` | vera-correct | §3.2.2: block comments do not nest, so `/*` and `(*` inside one are plain text and the comment ends at the first `*/`; iverilog's 'Possible nested comment' error is an Icarus lint |
| `string12` | vera-correct | §3.6: a string is contained on a single line; the backslash-newline continuation is IEEE 1800 §5.9, which iverilog accepts as an extension |
| `param-width` | vera-correct | §4.10.1 and §5.4.1: an untyped parameter takes the size of its final value, so 1'h1 + 1'h1 is 1 bit (0); iverilog widens untyped parameter arithmetic; ranged sum1/sum3 read as self-determined |
| `ca_time_real` `delayed_sfunc` `pr1864110a` `pr1864110b` `pr1864115` | vera-correct | §4.2/A.2.1.3: a net declaration takes no data type, so `wire real r;` is illegal in 1364-2005 (an Icarus extension; Verilator and yosys refuse too) |
| `pr2172606b` | vera-correct | §5.1.13 Table 5-21: an x/z select over z and z gives x, which VerA returns; the test's non-Icarus branch sets zz_blend = x and then fails on its own in_0 === in_1 check |
| `pr2453002` | vera-correct | §5.1.13: with an x/z condition and a real operand the result shall be 0; VerA gives 0.0, the test (and iverilog) expect 6.0 |
| `signed_a` | vera-correct | §5.2.2: an array index outside the declared range (2**120 + 7 for [1:8]) reads x; the test expects the high bits stripped (an Icarus truncation of the index) |
| `pr707` `pr938b` `udp_dff` | vera-correct | §8 / A.5.4 a UDP instance connects terminals by position only, each an expression: a named connection (.Q(qq)) or an empty trailing terminal is not 1364. VerA refuses, iverilog accepts |
| `pr3587570` | vera-correct | §8.1.4: the same input combination may not be given different outputs; `1 : 1;` and `? : 0;` both cover input 1 (yosys refuses too) |
| `nb_ec_multi_ev` `pv_wr_vec4_nb_ec` `pv_wr_vec4a_nb_ec` | vera-correct | §9.2.2/§11.4: an event-controlled nonblocking update lands in the NBA region, after the triggering thread's next statements; the test reads x right after -> e expecting the new value (Icarus applies it at once) |
| `assign3.2E` `assign_deassign_pv` `force_lval_part` `force_release_reg_pv` `pr1832097b` `pr2943394` | vera-correct | §9.3.1/§9.3.2 assign/deassign and force/release on a bit- or part-select of a reg (or a concatenation of them) is forbidden; VerA refuses, iverilog accepts |
| `br1000` | vera-correct | §9.7.5: both always @* blocks read and write the shared loop variable i, so each wakes the other forever at time 0; VerA oscillates (deterministic timeout), iverilog stops waking |
| `br_ml20190806a` `pr1002a` `pr1026` `pr1861212a` `pr1956211` `pr2043585` `pr2728812a` `pr2986528` | implementation-defined | §11.4: order of processes at time 0 is not defined; VerA settles initial values before always/@* processes wait, so time-0 changes (initial assignments, UDP init §8.5, constant ports) wake nothing |
| `pr812` `pr985` | implementation-defined | §11.4: the order in which simultaneously ready processes run (and so the order of their $display output) is not defined; VerA and iverilog interleave them differently |
| `br961` | implementation-defined | §12.7 scope rules do not settle whether `[w-1:0]` in `input [w-1:0] w;` names the port itself or the outer localparam; VerA (with verilator, yosys) refuses, iverilog takes the localparam. Unsure |
| `eofmt_percent` `format` | implementation-defined | §17.1.1 does not say what a malformed format does (a specification with no argument, a trailing lone %); VerA refuses, iverilog warns and prints it literally |
| `pr1701890` `pr1703120` `pr2792897` `pr584` | implementation-defined | §17.1.1.2 prints an argument without a format as decimal and leaves a real under %d unspecified: VerA prints the rounded integer at 64-bit width, iverilog %g-like text; inf/nan rendering is not defined either |
| `delay` `test_extended` | implementation-defined | §17.1.1.3 defines automatic sizing and the %0 override only: a field width like %04d/%08d, and the width of %d for a 1-bit signed value, are not defined; iverilog zero-pads and trims, VerA pads with spaces |
| `param_string` | implementation-defined | §17.1.1: a string-valued parameter passed as $display's only argument is an integral constant (§3.6); VerA prints it in decimal, iverilog as text |
| `monitor4` `pr243` | implementation-defined | §17.1.3/§17.4.1: a $monitor change in the time step where $finish or $monitoroff executes; VerA stops (or is off) before the end-of-step monitor print, iverilog still prints it |
| `scanf4` | implementation-defined | §17.2.4.3 lists the characters %b/%o/%h/%d accept but not how ? maps (VerA z as in §3.5.1, test x), whether a leading _ is a match, or x/z under %d; the test pins Icarus's choices |
| `pr1701855` | implementation-defined | §17.3.1: the module name $printtimescale prints is not fixed as full or as written; VerA prints the argument (dut), iverilog the full path (top.dut) |
| `itor_rtoi` | implementation-defined | §17.8 defines $itor for an integer argument only; a real argument (10.4) is unspecified. VerA refuses, iverilog converts it first |
| `include1` `include2` `include3` `pr224a` | implementation-defined | §19.5 leaves where a relative `include path is searched to the tool: VerA searches the including file's dir and -I dirs, not the cwd; iverilog finds "ivltests/x.v" from upstream's cwd ivtest/ |
| `pr903` | implementation-defined | §3.5.1: an unsized constant has at least 32 bits; VerA truncates 'h9000_..._0000 (80 bits) to 32, so the division is 0/0 = x, iverilog keeps 80 bits |
| `br947` `ldelay1` `ldelay3` `multi_driver_delay` `pr1645518` `pr1883052` `pr1883052b` `pr2801662` `pr528` `pr528b` | implementation-defined | §4.2.1 says a net with drivers assumes its drivers' value but not what a delayed continuous assignment, net delay or gate outputs before its first update; VerA reads z (b_4_2_1_net_z_before_delayed_driver.v), iverilog x |
| `gate_connect1` | implementation-defined | §7.1.6 sizes terminals only for instance arrays; a multi-bit expression on a single gate's input is unspecified (the test says so). VerA refuses, iverilog uses the LSB |
| `pr2937417b` `pr2937417c` | implementation-defined | §9.3.2 and §7.6 do not say whether a value forced on one side of a tran drives the other side; iverilog propagates it (y goes x), VerA does not (y keeps its driver); uncertain |
| `pr1587669` | implementation-defined | §4.2.1/§14.3: a net starts at z and takes its driver's value; with module path delays (0.5) VerA delays em's first z-to-x change too, so em reads z at time 0 and x at 0.5, where the gold (iverilog -gspecify) shows x from time 0; no clause fixes the destination's value before its first delayed transition |
| `br960a` `br960b` `br960c` `br960d` `br_gh889` `br_ml20190814` `sdf1` `sdf2` `sdf3` `sdf4` `sdf5` `sdf6` `sdf7` `sdf8` `sdf_esc_id` | out-of-scope | SDF back-annotation (clause 16, §17.2.10 $sdf_annotate with an .sdf file) is scoped out (CLAUSE-AUDIT §5.7) and refused by name (E1102) |
| `attrib_expr` `br_gh484` `macro_str_esc` `module_output_port_list_def` `nb_ec_concat` `real_array_multi_dim` `shift6` `vardly_undefined_vec` | out-of-scope | SystemVerilog preprocessing: the macro text uses IEEE 1800 `" / `\`" / `` / `__LINE__ (1800 §22.5.1); 1364-2005 §19.3.1 has none of them, so the expanded text is an error |
| `array_packed_2d` `br_gh497a` `br_gh497c` `br_gh497e` `br_gh531` `partsel_outside_const` `partsel_outside_expr` `random` | out-of-scope | SystemVerilog syntax in a regress-vlg test: packed multi-dimensional ranges, `integer unsigned`, `i++`, a compound assignment, unbased `'x` are IEEE 1800; 1364-2005 A.2/A.8 has none, so VerA's refusal is right |
| `br_gh1178b` `br_gh1178c` | out-of-scope | SystemVerilog: `logic` is no 1364-2005 keyword, so `logic passed;` is no legal 1364 item. VerA refuses (reading it as a VAMS discipline under --std=1364-2005), iverilog reads SV here |
| `pr2815398a` `pr2815398a_std` | out-of-scope | the expected output depends on `ifdef __ICARUS__ code VerA does not define (Icarus extensions); the non-Icarus branch prints different lines or cannot pass (pr2815398a never drives index 7) |

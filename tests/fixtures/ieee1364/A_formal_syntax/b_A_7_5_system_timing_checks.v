// IEEE 1364-2005 A.7.5.1, p. 502:
//   system_timing_check ::= $setup_timing_check | $hold_timing_check
//     | $setuphold_timing_check | $recovery_timing_check | $removal_timing_check
//     | $recrem_timing_check | $skew_timing_check | $timeskew_timing_check
//     | $fullskew_timing_check | $period_timing_check | $width_timing_check
//     | $nochange_timing_check
//   $setup_timing_check ::= $setup ( data_event , reference_event , timing_check_limit [ , [ notifier ] ] ) ;
//   $hold_timing_check ::= $hold ( reference_event , data_event , timing_check_limit [ , [ notifier ] ] ) ;
//   $setuphold_timing_check ::= $setuphold ( reference_event , data_event , timing_check_limit , timing_check_limit
//     [ , [ notifier ] [ , [ stamptime_condition ] [ , [ checktime_condition ]
//     [ , [ delayed_reference ] [ , [ delayed_data ] ] ] ] ] ] ) ;
//   $recovery_timing_check ::= $recovery ( reference_event , data_event , timing_check_limit [ , [ notifier ] ] ) ;
//   $removal_timing_check ::= $removal ( reference_event , data_event , timing_check_limit [ , [ notifier ] ] ) ;
//   $recrem_timing_check ::= $recrem ( reference_event , data_event , timing_check_limit , timing_check_limit
//     [ , [ notifier ] [ , [ stamptime_condition ] [ , [ checktime_condition ]
//     [ , [ delayed_reference ] [ , [ delayed_data ] ] ] ] ] ] ) ;
//   $skew_timing_check ::= $skew ( reference_event , data_event , timing_check_limit [ , [ notifier ] ] ) ;
//   $timeskew_timing_check ::= $timeskew ( reference_event , data_event , timing_check_limit
//     [ , [ notifier ] [ , [ event_based_flag ] [ , [ remain_active_flag ] ] ] ] ) ;
//   $fullskew_timing_check ::= $fullskew ( reference_event , data_event , timing_check_limit , timing_check_limit
//     [ , [ notifier ] [ , [ event_based_flag ] [ , [ remain_active_flag ] ] ] ] ) ;
//   $period_timing_check ::= $period ( controlled_reference_event , timing_check_limit [ , [ notifier ] ] ) ;
//   $width_timing_check ::= $width ( controlled_reference_event , timing_check_limit [ , threshold [ , notifier ] ] ) ;
//   $nochange_timing_check ::= $nochange ( reference_event , data_event , start_edge_offset ,
//     end_edge_offset [ , [ notifier ] ] ) ;
// A.7.5.2, p. 503:
//   checktime_condition ::= mintypmax_expression
//   controlled_reference_event ::= controlled_timing_check_event
//   data_event ::= timing_check_event
//   delayed_data ::= terminal_identifier | terminal_identifier [ constant_mintypmax_expression ]
//   delayed_reference ::= terminal_identifier | terminal_identifier [ constant_mintypmax_expression ]
//   end_edge_offset ::= mintypmax_expression
//   event_based_flag ::= constant_expression
//   notifier ::= variable_identifier
//   reference_event ::= timing_check_event
//   remain_active_flag ::= constant_expression
//   stamptime_condition ::= mintypmax_expression
//   start_edge_offset ::= mintypmax_expression
//   threshold ::= constant_expression
//   timing_check_limit ::= expression
// A.7.5.3, p. 503-504:
//   timing_check_event ::= [timing_check_event_control] specify_terminal_descriptor
//     [ &&& timing_check_condition ]
//   controlled_timing_check_event ::= timing_check_event_control specify_terminal_descriptor
//     [ &&& timing_check_condition ]
//   timing_check_event_control ::= posedge | negedge | edge_control_specifier
//   specify_terminal_descriptor ::= specify_input_terminal_descriptor | specify_output_terminal_descriptor
//   edge_control_specifier ::= edge [ edge_descriptor { , edge_descriptor } ]
//   edge_descriptor ::= 01 | 10 | z_or_x zero_or_one | zero_or_one z_or_x
//   zero_or_one ::= 0 | 1
//   z_or_x ::= x | X | z | Z
//   timing_check_condition ::= scalar_timing_check_condition | ( scalar_timing_check_condition )
//   scalar_timing_check_condition ::= expression | ~ expression | expression == scalar_constant
//     | expression === scalar_constant | expression != scalar_constant | expression !== scalar_constant
//   scalar_constant ::= 1'b0 | 1'b1 | 1'B0 | 1'B1 | 'b0 | 'b1 | 'B0 | 'B1 | 1 | 0
//
// All twelve checks, with every optional argument somewhere: notifiers, a
// null notifier (`, ,`), stamptime and checktime conditions, delayed
// reference and data signals (plain, and dbus[0] with a constant select for
// the vector port bit bus[0]), event-based
// and remain-active flags, a $width threshold, edge descriptors of all four
// shapes (01, 10, x1, 0z), and &&& conditions of every scalar form. Timing
// checks are not evaluated by VerA (W0251: §15 is outside the §1 B scope), so
// nothing toggles the notifier and the cell runs as its assignment:
// q = d = 1. Output: "q=1 ntfr=0".
// digital-runner: warning W0251
//! inherited IEEE 1364-2005 A.7.5.1,A.7.5.2,A.7.5.3
`timescale 1ns/1ns
module b_A_7_5_cell (clk, d, en, bus, q);
  input clk, d, en;
  input [1:0] bus;
  output q;
  reg ntfr;
  wire dclk, dd;
  wire [1:0] dbus;
  assign q = d;
  initial ntfr = 0;
  specify
    $setup(d, posedge clk, 1, ntfr);
    $hold(posedge clk, d, 1);
    $setuphold(posedge clk &&& en, negedge d, 1, 1, ntfr, en, en, dclk, dd);
    $recovery(posedge clk, d &&& ~en, 2);
    $removal(posedge clk, d &&& (en == 1'b1), 2, );
    $recrem(posedge bus[0], d &&& en === 'b1, 1, 1, ntfr, , , dbus[0], dd);
    $skew(posedge clk, d &&& en != 0, 3);
    $timeskew(posedge clk, negedge d &&& en !== 1'B0, 3, ntfr, 1, 0);
    $fullskew(posedge clk, negedge d, 3, 3, , 0, 1);
    $period(edge [01, 10] clk, 10);
    $width(edge [x1, 0z] clk, 4, 1, ntfr);
    $nochange(posedge clk, d, 0, 0, ntfr);
  endspecify
endmodule
module b_A_7_5_system_timing_checks;
  wire q;
  b_A_7_5_cell c (1'b1, 1'b1, 1'b1, 2'b01, q);
  initial #10 begin
    $display("q=%b ntfr=%0d", q, c.ntfr);
    $finish(0);
  end
endmodule

// IEEE 1364-2005 §13.3.2, p. 205: "It shall be an error for an instance
// clause to specify a hierarchical path to an instance that occurs within a
// hierarchy specified by another config." The clause's example, with its
// libraries collapsed to work:
//   instance top.bot use lib1.bot:config;
//   instance top.bot.a1 liblist lib4;
//     // ERROR - cannot set liblist for top.bot.a1 from this config
//
// The file holds two configs, and §13.4.4 names no rule for choosing the one
// that configures the design. This fixture takes the config no other config
// references (cfg), as §12.1.1 takes an uninstantiated module as a top;
// bot is reached only through cfg's use clause.
//
// top.bot is bound to config bot, so top.bot.a1 is inside the hierarchy bot
// specifies, and cfg's instance clause for it is the error. Legal neighbour:
// b_13_3_2_hierarchical_config.v (xfail), the binding without the rule.
// digital-runner: reject
//! inherited IEEE 1364-2005 13.3.2
//! reject another config
//! xfail every config's design cells become tops, so VerA refuses the file only as "digital execution requires exactly one top-level module"
config bot;
  design work.bot;
  default liblist work;
endconfig
config cfg;
  design work.top;
  default liblist work;
  instance top.bot use work.bot:config;
  instance top.bot.a1 liblist work;
endconfig
module leaf;
  initial $display("leaf");
endmodule
module bot;
  leaf a1();
endmodule
module top;
  bot bot();
endmodule

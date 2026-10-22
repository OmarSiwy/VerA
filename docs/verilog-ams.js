// Verilog-AMS highlighting for ```verilog blocks: mdbook's bundled
// highlight.js has no Verilog grammar. book.js has already run, so register
// the language and highlight those blocks again.
hljs.registerLanguage('verilog', function (hljs) {
  return {
    name: 'Verilog-AMS',
    aliases: ['va', 'vams'],
    keywords: {
      $pattern: /\$?[A-Za-z_][\w$]*/,
      keyword:
        'module macromodule endmodule connectmodule input output inout wire reg ' +
        'integer real realtime time genvar parameter localparam defparam ' +
        'aliasparam paramset endparamset from exclude assign always initial ' +
        'begin end fork join if else case casex casez endcase default for ' +
        'while repeat forever function endfunction task endtask automatic ' +
        'generate endgenerate posedge negedge or and not signed unsigned ' +
        'supply0 supply1 tri wand wor event specify endspecify disable wait ' +
        'analog electrical discipline enddiscipline nature endnature domain ' +
        'continuous discrete potential flow branch ground wreal string ' +
        'connectrules endconnectrules connect resolveto split merged ' +
        'abstol access ddt_nature idt_nature units net_discipline',
      built_in:
        'V I ddt idt idtmod ddx absdelay transition slew laplace_nd laplace_np ' +
        'laplace_zd laplace_zp zi_nd zi_np zi_zd zi_zp last_crossing cross ' +
        'above timer initial_step final_step limexp white_noise flicker_noise ' +
        'noise_table noise_table_log ln log exp sqrt pow abs min max floor ceil ' +
        'sin cos tan asin acos atan atan2 sinh cosh tanh asinh acosh atanh hypot ' +
        'analysis ac_stim',
      literal: 'inf',
    },
    contains: [
      hljs.C_LINE_COMMENT_MODE,
      hljs.C_BLOCK_COMMENT_MODE,
      hljs.QUOTE_STRING_MODE,
      { className: 'built_in', begin: /\$[A-Za-z_][\w$]*/ },
      { className: 'meta', begin: /`[A-Za-z_]\w*/ },
      { className: 'operator', begin: /<\+/ },
      {
        className: 'number',
        begin:
          /\d*'[sS]?[bBoOdDhH]\s*[0-9a-fA-FxXzZ_?]+|\b\d[\d_]*(\.[\d_]+)?([eE][+-]?\d+|[TGMKkmunpfa])?/,
        relevance: 0,
      },
    ],
  };
});

document.querySelectorAll('code.language-verilog').forEach(hljs.highlightBlock);

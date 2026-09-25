// Starts `vera --lsp` for Verilog-A documents. The flags come from the
// workspace root's `.vera-flags`, as on the command line.
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;

exports.activate = async function () {
  const command = vscode.workspace.getConfiguration('vera').get('path') || 'vera';
  client = new LanguageClient('vera', 'VerA', { command, args: ['--lsp'] }, {
    documentSelector: [{ scheme: 'file', language: 'verilog-ams' }],
  });
  await client.start();
};

exports.deactivate = function () {
  return client && client.stop();
};

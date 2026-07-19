#!/usr/bin/env node
// Uppercase stdin — demonstrates Node scripts work via shebang.
const chunks = [];
process.stdin.on('data', (c) => chunks.push(c));
process.stdin.on('end', () => {
  const text = Buffer.concat(chunks).toString('utf8');
  process.stdout.write(text.toUpperCase());
});

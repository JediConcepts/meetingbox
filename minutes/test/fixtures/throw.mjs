// Loaded with --import before writer.mjs: once the script is waiting on stdin, an exception nobody
// catches, with the key and the transcript in its message. The script must print only its fixed line.
setTimeout(() => {
  throw new Error("sk-test-0123456789abcdefghijKLMNOPQRSTUVwxyz BLUEHERON");
}, 500);

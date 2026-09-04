import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public final class MkChadTlsProxyTupleTest {
  private static final String TCP_HEADER =
      "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode                                                     \n";
  private static final String TCP6_HEADER =
      "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";

  private MkChadTlsProxyTupleTest() {}

  public static void main(String[] args) throws Exception {
    Path root = Path.of(args[0]);
    Files.createDirectories(root);
    Path tcp = root.resolve("tcp");
    Path tcp6 = root.resolve("tcp6");
    String local = "0100007F:9C40";
    String remote = "0100007F:C350";
    String match = row(0, local, remote, "01", "4242");
    Files.writeString(tcp, TCP_HEADER + match, StandardCharsets.US_ASCII);
    Files.writeString(tcp6, TCP6_HEADER, StandardCharsets.US_ASCII);
    String inode = MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote);
    if (!inode.equals("4242")) {
      throw new AssertionError("exact tuple returned the wrong inode");
    }

    Files.writeString(tcp, TCP_HEADER + match + row(1, local, remote, "01", "4243"), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp, TCP_HEADER + row(0, local, "0100007F:C351", "01", "4242"), StandardCharsets.US_ASCII);
    Files.writeString(tcp6, TCP6_HEADER, StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp, TCP_HEADER + match.stripTrailing(), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));

    String[] malformedFields = {
        replaceField(match, 4, "0000000:00000000"),
        replaceField(match, 5, "05:00000000"),
        replaceField(match, 6, "0000000Z"),
        replaceField(match, 7, "4294967296"),
        replaceField(match, 8, "-1"),
        replaceField(match, 9, "18446744073709551616"),
        replaceField(match, 10, "-1"),
        replaceField(match, 11, "pointer"),
        replaceField(match, 12, "18446744073709551616"),
        replaceField(match, 13, "-1"),
        replaceField(match, 14, "4294967296"),
        replaceField(match, 15, "4294967296"),
        replaceField(match, 16, "-2")
    };
    for (String malformed : malformedFields) {
      Files.writeString(tcp, TCP_HEADER + malformed, StandardCharsets.US_ASCII);
      expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    }
    Files.writeString(tcp, TCP_HEADER + removeLastField(match), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp, TCP_HEADER + match.stripTrailing() + " extra\n", StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp, TCP_HEADER + "malformed entry\n" + row(1, local, remote, "01", "4242"), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp, TCP_HEADER + row(0, "00000000000000000000000001000000:9C40", remote, "01", "4242"), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    String ipv6Local = "00000000000000000000000001000000:9C40";
    String ipv6Remote = "00000000000000000000000001000000:C350";
    Files.writeString(tcp, TCP_HEADER, StandardCharsets.US_ASCII);
    Files.writeString(tcp6, TCP6_HEADER + row(0, ipv6Local, ipv6Remote, "01", "5252"), StandardCharsets.US_ASCII);
    if (!MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), ipv6Local, ipv6Remote).equals("5252")) {
      throw new AssertionError("valid actual-format IPv6 row was rejected");
    }
    Files.writeString(tcp6, TCP6_HEADER + row(0, local, remote, "01", "5252"), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp, TCP_HEADER + match, StandardCharsets.US_ASCII);
    Files.writeString(tcp6, TCP6_HEADER + row(0, local, remote, "01", "5252"), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));

    String timeWait = shortRow(0, local, remote, "06", "0");
    Files.writeString(tcp, TCP_HEADER + timeWait + row(1, local, remote, "01", "4242"), StandardCharsets.US_ASCII);
    Files.writeString(tcp6, TCP6_HEADER, StandardCharsets.US_ASCII);
    if (!MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote).equals("4242")) {
      throw new AssertionError("valid 12-column TIME_WAIT row was rejected");
    }

    String finWait2 = shortRow(0, "1F02A8C0:CC87", "99BBCD6D:1090", "05", "0");
    Files.writeString(tcp, TCP_HEADER + finWait2 + row(1, local, remote, "01", "4242"), StandardCharsets.US_ASCII);
    if (!MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote).equals("4242")) {
      throw new AssertionError("valid 12-column FIN_WAIT2 row was rejected");
    }

    Files.writeString(tcp, TCP_HEADER + match, StandardCharsets.US_ASCII);
    Files.writeString(tcp6, "", StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp6, match, StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp6, TCP6_HEADER + TCP6_HEADER, StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp6, TCP6_HEADER.replace("remote_address", "remote_addr"), StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
    Files.writeString(tcp6, match + TCP6_HEADER, StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), local, remote));
  }

  private static String row(int index, String local, String remote, String state, String inode) {
    return index + ": " + local + " " + remote + " " + state
        + " 00000000:00000000 00:00000000 00000000 1000 0 " + inode
        + " 1 0000000000000000 100 0 0 10 0\n";
  }

  private static String shortRow(int index, String local, String remote, String state, String inode) {
    return index + ": " + local + " " + remote + " " + state
        + " 00000000:00000000 03:00000000 00000000 0 0 " + inode
        + " 1 0000000000000000\n";
  }

  private static String replaceField(String row, int index, String replacement) {
    String[] fields = row.strip().split("\\s+");
    fields[index] = replacement;
    return String.join(" ", fields) + "\n";
  }

  private static String removeLastField(String row) {
    String[] fields = row.strip().split("\\s+");
    return String.join(" ", java.util.Arrays.copyOf(fields, fields.length - 1)) + "\n";
  }

  private static void expectFailure(Checked operation) throws Exception {
    try {
      operation.run();
      throw new AssertionError("tuple mismatch or ambiguity was accepted");
    } catch (IOException expected) {
      // Exact tuple proof must fail closed.
    }
  }

  @FunctionalInterface
  private interface Checked {
    void run() throws Exception;
  }
}

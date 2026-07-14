import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public final class MkChadTlsProxyLargeTableTest {
  private static final String LOCAL = "0100007F:9C40";
  private static final String REMOTE = "0100007F:C350";
  private static final String TCP_HEADER =
      "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n";
  private static final String TCP6_HEADER =
      "sl local_address remote_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n";

  private MkChadTlsProxyLargeTableTest() {}

  public static void main(String[] args) throws Exception {
    Path root = Path.of(args[0]);
    Files.createDirectories(root);
    Path tcp = root.resolve("tcp-large");
    Path tcp6 = root.resolve("tcp6-large");
    writeLargeTable(tcp, true, 80_000);
    Files.writeString(tcp6, TCP6_HEADER, StandardCharsets.US_ASCII);

    String inode = MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), LOCAL, REMOTE);
    if (!inode.equals("4242")) {
      throw new AssertionError("large streaming scan returned the wrong inode");
    }

    Path overlong = root.resolve("tcp-overlong");
    Files.writeString(overlong, "x".repeat(4097) + "\n", StandardCharsets.US_ASCII);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(overlong, tcp6), LOCAL, REMOTE));

    Path oversized = root.resolve("tcp-oversized");
    writeLargeTable(oversized, false, 190_000);
    expectFailure(() -> MkChadTlsProxy.findUniqueEstablishedInode(List.of(oversized, tcp6), LOCAL, REMOTE));

    MkChadTlsProxy.resetProofScanMetrics();
    int tasks = 24;
    CountDownLatch start = new CountDownLatch(1);
    try (var executor = Executors.newFixedThreadPool(tasks)) {
      List<Future<String>> results = new ArrayList<>();
      for (int i = 0; i < tasks; i++) {
        results.add(executor.submit(() -> {
          start.await();
          return MkChadTlsProxy.findUniqueEstablishedInode(List.of(tcp, tcp6), LOCAL, REMOTE);
        }));
      }
      start.countDown();
      for (Future<String> result : results) {
        if (!result.get().equals("4242")) {
          throw new AssertionError("concurrent scan returned the wrong inode");
        }
      }
    }
    int observed = MkChadTlsProxy.maxObservedProofScans();
    if (observed < 2 || observed > MkChadTlsProxy.proofScanLimit()) {
      throw new AssertionError("proof scan concurrency was not separately bounded: " + observed);
    }
  }

  private static void writeLargeTable(Path path, boolean includeMatch, int entries) throws IOException {
    try (BufferedWriter writer = Files.newBufferedWriter(path, StandardCharsets.US_ASCII)) {
      writer.write(TCP_HEADER);
      for (int i = 0; i < entries; i++) {
        String remote = includeMatch && i == entries / 2 ? REMOTE : "0100007F:C351";
        String inode = includeMatch && i == entries / 2 ? "4242" : "1234";
        writer.write(i + ": " + LOCAL + " " + remote
            + " 01 00000000:00000000 00:00000000 00000000 1000 0 " + inode
            + " 1 0000000000000000 100 0 0 10 0\n");
      }
    }
  }

  private static void expectFailure(Checked operation) throws Exception {
    try {
      operation.run();
      throw new AssertionError("a partial or bounded-out scan was accepted as proof");
    } catch (IOException expected) {
      // Bounds must reject the entire proof rather than accept a partial scan.
    }
  }

  @FunctionalInterface
  private interface Checked {
    void run() throws Exception;
  }
}

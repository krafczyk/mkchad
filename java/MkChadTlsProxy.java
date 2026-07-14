import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLServerSocketFactory;
import javax.net.ssl.SSLSocket;

/** A loopback TLS relay that proves ownership of each established backend socket. */
public final class MkChadTlsProxy {
  private static final byte[] PREFLIGHT = (
      "GET /global/health HTTP/1.1\r\n"
          + "Host: 127.0.0.1\r\n"
          + "Accept: application/json\r\n"
          + "Connection: keep-alive\r\n\r\n")
      .getBytes(StandardCharsets.US_ASCII);
  private static final int HEADER_LIMIT = 16 * 1024;
  private static final int BODY_LIMIT = 64 * 1024;
  private static final int PROOF_TIMEOUT_MS = 3000;
  private static final int PROC_LINE_LIMIT = 4096;
  private static final int PROC_ENTRY_LIMIT = 200_000;
  private static final int PROC_BYTE_LIMIT = 16 * 1024 * 1024;
  private static final long PROC_SCAN_TIMEOUT_NANOS = Duration.ofSeconds(5).toNanos();
  private static final int MAX_CONCURRENT_PROOF_SCANS = 8;
  private static final Semaphore PROOF_SCAN_PERMITS = new Semaphore(MAX_CONCURRENT_PROOF_SCANS, true);
  private static final AtomicInteger ACTIVE_PROOF_SCANS = new AtomicInteger();
  private static final AtomicInteger MAX_OBSERVED_PROOF_SCANS = new AtomicInteger();
  private static final String[] TCP_HEADER = {
      "sl", "local_address", "rem_address", "st", "tx_queue", "rx_queue", "tr", "tm->when",
      "retrnsmt", "uid", "timeout", "inode"
  };
  private static final String[] TCP6_HEADER = {
      "sl", "local_address", "remote_address", "st", "tx_queue", "rx_queue", "tr", "tm->when",
      "retrnsmt", "uid", "timeout", "inode"
  };
  private static final Pattern WHITESPACE = Pattern.compile("\\s+");
  private static final String UINT_MAX = "4294967295";
  private static final String INT_MAX = "2147483647";
  private static final String ULONG_MAX = "18446744073709551615";

  private record Config(
      int listenPort,
      int backendPort,
      long backendPid,
      String backendStart,
      String bootId,
      Path keyStore,
      Path passwordFile,
      int maxConnections) {}

  private MkChadTlsProxy() {}

  public static void main(String[] args) throws Exception {
    if (args.length == 8
        && args[0].equals("--validate-keystore")
        && args[2].equals("--password-file")
        && args[4].equals("--ca-file")
        && args[6].equals("--ca-keystore")) {
      validateKeyStore(Path.of(args[1]), Path.of(args[3]), Path.of(args[5]), Path.of(args[7]));
      return;
    }
    Config config = parse(args);
    requireLinuxEvidence(config);
    SSLContext context = tlsContext(config);
    SSLServerSocketFactory factory = context.getServerSocketFactory();
    SSLServerSocket server = (SSLServerSocket) factory.createServerSocket();
    server.setReuseAddress(false);
    server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), config.listenPort()));
    Set<String> supported = Set.of(server.getSupportedProtocols());
    String[] protocols = Arrays.stream(new String[] {"TLSv1.3", "TLSv1.2"})
        .filter(supported::contains)
        .toArray(String[]::new);
    if (protocols.length == 0) {
      throw new IOException("TLS 1.2 or newer is unavailable");
    }
    server.setEnabledProtocols(protocols);
    SSLParameters parameters = server.getSSLParameters();
    parameters.setApplicationProtocols(new String[0]);
    server.setSSLParameters(parameters);

    Semaphore permits = new Semaphore(config.maxConnections());
    Runtime.getRuntime().addShutdownHook(new Thread(() -> close(server)));
    while (true) {
      SSLSocket client = (SSLSocket) server.accept();
      if (!permits.tryAcquire()) {
        close(client);
        continue;
      }
      Thread.ofVirtual().start(() -> {
        try {
          relay(client, config);
        } catch (Exception ignored) {
          close(client);
        } finally {
          permits.release();
        }
      });
    }
  }

  private static Config parse(String[] args) {
    Map<String, String> values = new HashMap<>();
    for (int i = 0; i < args.length; i += 2) {
      if (i + 1 >= args.length || !args[i].startsWith("--") || values.put(args[i], args[i + 1]) != null) {
        throw new IllegalArgumentException("invalid or duplicate proxy argument");
      }
    }
    int listenPort = port(values, "--listen-port");
    int backendPort = port(values, "--backend-port");
    long backendPid = Long.parseLong(required(values, "--backend-pid"));
    int maxConnections = Integer.parseInt(required(values, "--max-connections"));
    if (backendPid <= 0 || maxConnections < 1 || maxConnections > 1024 || values.size() != 8) {
      throw new IllegalArgumentException("invalid proxy bounds");
    }
    return new Config(
        listenPort,
        backendPort,
        backendPid,
        required(values, "--backend-start"),
        required(values, "--boot-id"),
        Path.of(required(values, "--keystore")),
        Path.of(required(values, "--password-file")),
        maxConnections);
  }

  private static String required(Map<String, String> values, String key) {
    String value = values.get(key);
    if (value == null || value.isEmpty()) {
      throw new IllegalArgumentException("missing " + key);
    }
    return value;
  }

  private static int port(Map<String, String> values, String key) {
    int value = Integer.parseInt(required(values, key));
    if (value < 1 || value > 65535) {
      throw new IllegalArgumentException("invalid " + key);
    }
    return value;
  }

  private static SSLContext tlsContext(Config config) throws Exception {
    KeyStore store = loadKeyStore(config.keyStore(), config.passwordFile());
    validateCertificates(store, null);
    char[] password = Files.readString(config.passwordFile(), StandardCharsets.US_ASCII).trim().toCharArray();
    try {
      KeyManagerFactory managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
      managers.init(store, password);
      SSLContext context = SSLContext.getInstance("TLS");
      context.init(managers.getKeyManagers(), null, null);
      return context;
    } finally {
      Arrays.fill(password, '\0');
    }
  }

  private static KeyStore loadKeyStore(Path keyStore, Path passwordFile) throws Exception {
    char[] password = Files.readString(passwordFile, StandardCharsets.US_ASCII).trim().toCharArray();
    try (InputStream input = Files.newInputStream(keyStore)) {
      KeyStore store = KeyStore.getInstance("PKCS12");
      store.load(input, password);
      return store;
    } finally {
      Arrays.fill(password, '\0');
    }
  }

  private static void validateKeyStore(Path keyStore, Path passwordFile, Path caFile, Path caKeyStore) throws Exception {
    KeyStore store = loadKeyStore(keyStore, passwordFile);
    KeyStore caStore = loadKeyStore(caKeyStore, passwordFile);
    X509Certificate ca;
    try (InputStream input = Files.newInputStream(caFile)) {
      ca = (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(input);
    }
    validateCertificates(store, ca);
    if (!(caStore.getCertificate("mkchad-ca") instanceof X509Certificate signingCa)
        || !Arrays.equals(ca.getEncoded(), signingCa.getEncoded())) {
      throw new IOException("CA keystore does not match the published host CA");
    }
  }

  private static void validateCertificates(KeyStore store, X509Certificate expectedCa) throws Exception {
    var chain = store.getCertificateChain("server");
    if (chain == null || chain.length < 2
        || !(chain[0] instanceof X509Certificate leaf)
        || !(chain[chain.length - 1] instanceof X509Certificate ca)) {
      throw new IOException("server certificate chain is incomplete");
    }
    leaf.checkValidity();
    ca.checkValidity();
    leaf.verify(ca.getPublicKey());
    ca.verify(ca.getPublicKey());
    if (ca.getBasicConstraints() < 0 || (expectedCa != null && !Arrays.equals(ca.getEncoded(), expectedCa.getEncoded()))) {
      throw new IOException("server chain does not match the host CA");
    }
    boolean loopbackSan = false;
    Collection<List<?>> names = leaf.getSubjectAlternativeNames();
    if (names != null) {
      for (List<?> name : names) {
        if (name.size() >= 2 && Integer.valueOf(7).equals(name.get(0)) && "127.0.0.1".equals(name.get(1))) {
          loopbackSan = true;
        }
      }
    }
    List<String> usages = leaf.getExtendedKeyUsage();
    if (!loopbackSan || usages == null || !usages.contains("1.3.6.1.5.5.7.3.1")) {
      throw new IOException("server certificate is not valid for TLS on 127.0.0.1");
    }
  }

  private static void relay(SSLSocket client, Config config) throws Exception {
    client.setSoTimeout(PROOF_TIMEOUT_MS);
    SSLParameters parameters = client.getSSLParameters();
    parameters.setApplicationProtocols(new String[0]);
    client.setSSLParameters(parameters);
    client.startHandshake();

    // No decrypted client byte is read until this immutable process identity is live.
    requireLinuxEvidence(config);
    try (client; Socket backend = new Socket()) {
      backend.connect(new InetSocketAddress("127.0.0.1", config.backendPort()), PROOF_TIMEOUT_MS);
      backend.setSoTimeout(PROOF_TIMEOUT_MS);
      backend.getOutputStream().write(PREFLIGHT);
      backend.getOutputStream().flush();
      consumePreflight(backend.getInputStream());

      requireLinuxEvidence(config);
      String inode = proveEstablishedSocket(backend, config);
      client.setSoTimeout(0);
      backend.setSoTimeout(0);
      pump(client, backend, config, inode);
    }
  }

  private static void consumePreflight(InputStream input) throws IOException {
    ByteArrayOutputStream header = new ByteArrayOutputStream();
    int matched = 0;
    while (header.size() < HEADER_LIMIT && matched < 4) {
      int value = input.read();
      if (value < 0) {
        throw new IOException("backend closed during preflight headers");
      }
      header.write(value);
      matched = switch (matched) {
        case 0 -> value == '\r' ? 1 : 0;
        case 1 -> value == '\n' ? 2 : (value == '\r' ? 1 : 0);
        case 2 -> value == '\r' ? 3 : 0;
        case 3 -> value == '\n' ? 4 : 0;
        default -> matched;
      };
    }
    if (matched != 4) {
      throw new IOException("backend preflight headers are oversized or malformed");
    }
    String text = header.toString(StandardCharsets.ISO_8859_1);
    String[] lines = text.substring(0, text.length() - 4).split("\\r\\n", -1);
    if (lines.length == 0 || !lines[0].matches("HTTP/1\\.[01] (200|401)( .*)?")) {
      throw new IOException("backend preflight returned an unsupported status");
    }
    long length = -1;
    for (int i = 1; i < lines.length; i++) {
      int colon = lines[i].indexOf(':');
      if (colon <= 0) {
        throw new IOException("backend preflight header is malformed");
      }
      String name = lines[i].substring(0, colon).trim().toLowerCase(Locale.ROOT);
      String value = lines[i].substring(colon + 1).trim();
      if (name.equals("transfer-encoding")) {
        throw new IOException("backend preflight transfer encoding is unsupported");
      }
      if (name.equals("connection") && value.toLowerCase(Locale.ROOT).contains("close")) {
        throw new IOException("backend preflight would close the proved connection");
      }
      if (name.equals("content-length")) {
        if (length >= 0 || !value.matches("[0-9]+")) {
          throw new IOException("backend preflight content length is malformed");
        }
        length = Long.parseLong(value);
      }
    }
    if (length < 0 || length > BODY_LIMIT) {
      throw new IOException("backend preflight body is unbounded or oversized");
    }
    for (long remaining = length; remaining > 0; ) {
      long skipped = input.skip(remaining);
      if (skipped > 0) {
        remaining -= skipped;
      } else if (input.read() >= 0) {
        remaining--;
      } else {
        throw new IOException("backend closed during preflight body");
      }
    }
  }

  private static String proveEstablishedSocket(Socket backend, Config config) throws IOException {
    InetSocketAddress proxySide = (InetSocketAddress) backend.getLocalSocketAddress();
    InetSocketAddress backendSide = (InetSocketAddress) backend.getRemoteSocketAddress();
    String wantedLocal = procAddress(backendSide);
    String wantedRemote = procAddress(proxySide);
    String inode = findUniqueEstablishedInode(
        List.of(Path.of("/proc/net/tcp"), Path.of("/proc/net/tcp6")), wantedLocal, wantedRemote);
    if (!ownsInode(config.backendPid(), inode)) {
      throw new IOException("backend established-socket ownership proof failed");
    }
    return inode;
  }

  static String findUniqueEstablishedInode(List<Path> tables, String wantedLocal, String wantedRemote)
      throws IOException {
    boolean acquired;
    try {
      acquired = PROOF_SCAN_PERMITS.tryAcquire(PROOF_TIMEOUT_MS, TimeUnit.MILLISECONDS);
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
      throw new IOException("interrupted while waiting for a proc proof scan", interrupted);
    }
    if (!acquired) {
      throw new IOException("concurrent proc proof scan limit reached");
    }
    int active = ACTIVE_PROOF_SCANS.incrementAndGet();
    MAX_OBSERVED_PROOF_SCANS.accumulateAndGet(active, Math::max);
    try {
      if (tables.size() != 2) {
        throw new IOException("both proc TCP tables are required");
      }
      ProcScan scan = new ProcScan(System.nanoTime() + PROC_SCAN_TIMEOUT_NANOS);
      scanTable(tables.get(0), TCP_HEADER, 8, wantedLocal, wantedRemote, scan);
      scanTable(tables.get(1), TCP6_HEADER, 32, wantedLocal, wantedRemote, scan);
      if (scan.matches != 1 || scan.inode == null) {
        throw new IOException("backend established tuple is absent or ambiguous");
      }
      return scan.inode;
    } finally {
      ACTIVE_PROOF_SCANS.decrementAndGet();
      PROOF_SCAN_PERMITS.release();
    }
  }

  private static void scanTable(
      Path table,
      String[] expectedHeader,
      int addressWidth,
      String wantedLocal,
      String wantedRemote,
      ProcScan scan)
      throws IOException {
    if (System.nanoTime() > scan.deadlineNanos || !Files.isReadable(table)) {
      throw new IOException("proc TCP table is unreadable: " + table);
    }
    byte[] line = new byte[PROC_LINE_LIMIT];
    int length = 0;
    int lines = 0;
    try (InputStream input = new BufferedInputStream(Files.newInputStream(table), 16 * 1024)) {
      for (int value; (value = input.read()) >= 0; ) {
        if (++scan.bytes > PROC_BYTE_LIMIT || System.nanoTime() > scan.deadlineNanos) {
          throw new IOException("proc TCP table scan exceeded its byte or time bound");
        }
        if (value == '\n') {
          scanLine(
              line,
              length,
              lines == 0,
              expectedHeader,
              addressWidth,
              wantedLocal,
              wantedRemote,
              scan);
          lines++;
          length = 0;
        } else {
          if (length >= line.length) {
            throw new IOException("proc TCP table line exceeded its bound");
          }
          line[length++] = (byte) value;
        }
      }
      if (length > 0) {
        throw new IOException("proc TCP table ended with a truncated line");
      }
    }
    if (lines == 0 || System.nanoTime() > scan.deadlineNanos) {
      throw new IOException("proc TCP table is empty or exceeded its time bound");
    }
  }

  private static void scanLine(
      byte[] line,
      int length,
      boolean firstLine,
      String[] expectedHeader,
      int addressWidth,
      String wantedLocal,
      String wantedRemote,
      ProcScan scan)
      throws IOException {
    if (++scan.entries > PROC_ENTRY_LIMIT) {
      throw new IOException("proc TCP table entry count exceeded its bound");
    }
    for (int i = 0; i < length; i++) {
      if (line[i] < 0x20 || line[i] > 0x7e) {
        throw new IOException("proc TCP table entry contains non-printable data");
      }
    }
    String text = new String(line, 0, length, StandardCharsets.US_ASCII).trim();
    String[] fields = WHITESPACE.split(text);
    if (firstLine) {
      if (!Arrays.equals(fields, expectedHeader)) {
        throw new IOException("proc TCP table header is malformed or missing");
      }
      return;
    }
    validateProcEntry(fields, addressWidth);
    if (fields[1].equalsIgnoreCase(wantedLocal)
        && fields[2].equalsIgnoreCase(wantedRemote)
        && fields[3].equals("01")) {
      scan.matches++;
      scan.inode = fields[9];
    }
  }

  private static void validateProcEntry(String[] fields, int addressWidth) throws IOException {
    if (fields.length < 4
        || !isSlot(fields[0])
        || !isProcEndpoint(fields[1], addressWidth)
        || !isProcEndpoint(fields[2], addressWidth)
        || !isFixedHex(fields[3], 2)) {
      throw new IOException("proc TCP table entry is malformed");
    }
    int state = Integer.parseInt(fields[3], 16);
    int expectedFields = state == 3 || state == 6 ? 12 : 17;
    if (state < 1
        || state > 13
        || fields.length != expectedFields
        || !isHexPair(fields[4], 8, 8)
        || !isHexPair(fields[5], 2, 8)
        || Integer.parseInt(fields[5].substring(0, 2), 16) > 4
        || !isFixedHex(fields[6], 8)
        || !isUnsignedDecimal(fields[7], UINT_MAX)
        || !isUnsignedDecimal(fields[8], INT_MAX)
        || !isUnsignedDecimal(fields[9], ULONG_MAX)
        || !isUnsignedDecimal(fields[10], INT_MAX)
        || !(isFixedHex(fields[11], 8) || isFixedHex(fields[11], 16))) {
      throw new IOException("proc TCP table entry is malformed");
    }
    if (expectedFields == 17
        && (!isUnsignedDecimal(fields[12], ULONG_MAX)
            || !isUnsignedDecimal(fields[13], ULONG_MAX)
            || !isUnsignedDecimal(fields[14], UINT_MAX)
            || !isUnsignedDecimal(fields[15], UINT_MAX)
            || !(fields[16].equals("-1") || isUnsignedDecimal(fields[16], INT_MAX)))) {
      throw new IOException("proc TCP table entry is malformed");
    }
  }

  private static boolean isSlot(String value) {
    return value.endsWith(":")
        && isUnsignedDecimal(value.substring(0, value.length() - 1), INT_MAX);
  }

  private static boolean isProcEndpoint(String value, int addressWidth) {
    return value.length() == addressWidth + 5
        && value.charAt(addressWidth) == ':'
        && isFixedHex(value.substring(0, addressWidth), addressWidth)
        && isFixedHex(value.substring(addressWidth + 1), 4);
  }

  private static boolean isHexPair(String value, int leftWidth, int rightWidth) {
    return value.length() == leftWidth + rightWidth + 1
        && value.charAt(leftWidth) == ':'
        && isFixedHex(value.substring(0, leftWidth), leftWidth)
        && isFixedHex(value.substring(leftWidth + 1), rightWidth);
  }

  private static boolean isFixedHex(String value, int width) {
    if (value.length() != width) {
      return false;
    }
    for (int i = 0; i < value.length(); i++) {
      char character = value.charAt(i);
      if (!((character >= '0' && character <= '9')
          || (character >= 'A' && character <= 'F')
          || (character >= 'a' && character <= 'f'))) {
        return false;
      }
    }
    return true;
  }

  private static boolean isUnsignedDecimal(String value, String maximum) {
    if (value.isEmpty()
        || (value.length() > 1 && value.charAt(0) == '0')
        || value.length() > maximum.length()) {
      return false;
    }
    for (int i = 0; i < value.length(); i++) {
      if (value.charAt(i) < '0' || value.charAt(i) > '9') {
        return false;
      }
    }
    return value.length() < maximum.length() || value.compareTo(maximum) <= 0;
  }

  static int proofScanLimit() {
    return MAX_CONCURRENT_PROOF_SCANS;
  }

  static void resetProofScanMetrics() {
    if (ACTIVE_PROOF_SCANS.get() != 0) {
      throw new IllegalStateException("cannot reset active proof scan metrics");
    }
    MAX_OBSERVED_PROOF_SCANS.set(0);
  }

  static int maxObservedProofScans() {
    return MAX_OBSERVED_PROOF_SCANS.get();
  }

  private static final class ProcScan {
    private final long deadlineNanos;
    private int bytes;
    private int entries;
    private int matches;
    private String inode;

    private ProcScan(long deadlineNanos) {
      this.deadlineNanos = deadlineNanos;
    }
  }

  private static String procAddress(InetSocketAddress address) throws IOException {
    byte[] bytes = address.getAddress().getAddress();
    StringBuilder result = new StringBuilder();
    if (address.getAddress() instanceof Inet4Address) {
      for (int i = 3; i >= 0; i--) {
        result.append("%02X".formatted(bytes[i] & 0xff));
      }
    } else if (address.getAddress() instanceof Inet6Address) {
      for (int word = 0; word < 4; word++) {
        for (int i = word * 4 + 3; i >= word * 4; i--) {
          result.append("%02X".formatted(bytes[i] & 0xff));
        }
      }
    } else {
      throw new IOException("unsupported backend address family");
    }
    return result.append(":%04X".formatted(address.getPort())).toString();
  }

  private static void pump(SSLSocket client, Socket backend, Config config, String inode) throws InterruptedException {
    AtomicBoolean done = new AtomicBoolean(false);
    Thread upstream = copyThread(client, backend, done);
    Thread downstream = copyThread(backend, client, done);
    while (!done.get()) {
      try {
        Thread.sleep(Duration.ofMillis(250));
        requireLinuxEvidence(config);
        if (!ownsInode(config.backendPid(), inode)) {
          throw new IOException("backend socket ownership was lost");
        }
      } catch (Exception failure) {
        done.set(true);
        close(client);
        close(backend);
      }
    }
    close(client);
    close(backend);
    upstream.join();
    downstream.join();
  }

  private static Thread copyThread(Socket source, Socket destination, AtomicBoolean done) {
    return Thread.ofVirtual().start(() -> {
      byte[] buffer = new byte[16 * 1024];
      try {
        InputStream input = source.getInputStream();
        OutputStream output = destination.getOutputStream();
        for (int count; !done.get() && (count = input.read(buffer)) >= 0; ) {
          if (count > 0) {
            output.write(buffer, 0, count);
            output.flush();
          }
        }
      } catch (IOException ignored) {
        // Either peer closing terminates both directions below.
      } finally {
        done.set(true);
        close(source);
        close(destination);
      }
    });
  }

  private static void requireLinuxEvidence(Config config) throws IOException {
    Path proc = Path.of("/proc", Long.toString(config.backendPid()));
    if (!Files.isDirectory(proc)
        || !Files.readString(Path.of("/proc/sys/kernel/random/boot_id"), StandardCharsets.US_ASCII).trim().equals(config.bootId())
        || !processStart(proc.resolve("stat")).equals(config.backendStart())) {
      throw new IOException("backend process identity changed");
    }
  }

  private static String processStart(Path statPath) throws IOException {
    String stat = Files.readString(statPath, StandardCharsets.US_ASCII);
    int close = stat.lastIndexOf(')');
    if (close < 0) {
      throw new IOException("malformed backend process stat");
    }
    String[] fields = stat.substring(close + 1).trim().split("\\s+");
    if (fields.length < 20) {
      throw new IOException("incomplete backend process stat");
    }
    return fields[19];
  }

  private static boolean ownsInode(long pid, String inode) throws IOException {
    Path fds = Path.of("/proc", Long.toString(pid), "fd");
    if (!Files.isDirectory(fds)) {
      return false;
    }
    String wanted = "socket:[" + inode + "]";
    try (var entries = Files.list(fds)) {
      return entries.anyMatch(path -> {
        try {
          return Files.readSymbolicLink(path).toString().equals(wanted);
        } catch (IOException ignored) {
          return false;
        }
      });
    }
  }

  private static void close(AutoCloseable closeable) {
    try {
      closeable.close();
    } catch (Exception ignored) {
      // Closing is idempotent cleanup after either pump direction exits.
    }
  }
}

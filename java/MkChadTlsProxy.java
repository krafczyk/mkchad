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
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.file.LinkOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collection;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.HashSet;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.CountDownLatch;
import java.util.regex.Pattern;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLServerSocketFactory;
import javax.net.ssl.SSLSocket;

/**
 * A loopback TLS broker that launches or explicitly adopts one verified backend
 * and proves ownership of every relayed backend socket.
 */
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
  private static final int CONTROL_FRAME_LIMIT = 64 * 1024;
  private static final int CONTROL_CONNECTION_LIMIT = 8;
  private static final int CONTROL_QUEUE_LIMIT = 16;
  private static final long CONTROL_DEADLINE_NANOS = Duration.ofSeconds(3).toNanos();
  private static final long PIDFD_TERM_GRACE_NANOS = Duration.ofMillis(250).toNanos();
  private static final int HELPER_OUTPUT_LIMIT = 64 * 1024;
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

  private record BrokerConfig(
      Path stateRoot,
      Path control,
      String generation,
      String bootId,
      Path backendExecutable,
      String backendVersion,
      int backendPort,
      int listenPort,
      Path keyStore,
      Path passwordFile,
      int maxConnections,
      Path backendLog,
      Path pidfdPython,
      Path pidfdHelper,
      Long adoptedBackendPid,
      String adoptedBackendStart) {}

  private record BrokerAuthority(
      long pid,
      String start,
      Path runtimePath,
      FileIdentity runtime,
      Path launchPath,
      FileIdentity launch,
      List<String> argv,
      Path source,
      FileIdentity sourceIdentity,
      FileIdentity backendExecutable,
      FileIdentity pidfdPython,
      FileIdentity pidfdHelper) {}

  private record ControlRequest(String operation, String generation, String nonce) {}

  private enum BrokerPhase {
    CONTROL_READY("control-ready"),
    ACTIVATING("activating"),
    RUNNING("running"),
    UNHEALTHY("unhealthy"),
    ACTIVATION_FAILED("activation-failed"),
    STOPPING("stopping"),
    STOPPED("stopped"),
    BLOCKED("blocked");

    private final String wire;

    BrokerPhase(String wire) {
      this.wire = wire;
    }
  }

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
    if (args.length > 0 && args[0].equals("--broker")) {
      runBroker(parseBroker(Arrays.copyOfRange(args, 1, args.length)));
      return;
    }
    Config config = parse(args);
    requireLinuxEvidence(config);
    serveTls(config);
  }

  private static void serveTls(Config config) throws Exception {
    SSLServerSocket server = openTlsServer(config);

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

  private static SSLServerSocket openTlsServer(Config config) throws Exception {
    SSLContext context = tlsContext(config);
    SSLServerSocketFactory factory = context.getServerSocketFactory();
    SSLServerSocket server = (SSLServerSocket) factory.createServerSocket();
    server.setReuseAddress(true);
    server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), config.listenPort()));
    Set<String> supported = Set.of(server.getSupportedProtocols());
    String[] protocols = Arrays.stream(new String[] {"TLSv1.3", "TLSv1.2"})
        .filter(supported::contains)
        .toArray(String[]::new);
    if (protocols.length == 0) {
      close(server);
      throw new IOException("TLS 1.2 or newer is unavailable");
    }
    server.setEnabledProtocols(protocols);
    SSLParameters parameters = server.getSSLParameters();
    parameters.setApplicationProtocols(new String[0]);
    server.setSSLParameters(parameters);
    return server;
  }

  /** Broker-only listener ownership: no accepted peer can escape the stop registry. */
  private static final class BrokerTlsService {
    private final Config config;
    private final Object registryLock = new Object();
    private final Set<RelayRegistration> relays = new HashSet<>();
    private volatile SSLServerSocket listener;
    private volatile Thread acceptThread;
    private boolean stopping;

    private BrokerTlsService(Config config) {
      this.config = config;
    }

    private void start() throws Exception {
      listener = openTlsServer(config);
      acceptThread = Thread.ofVirtual().start(this::accept);
    }

    private void accept() {
      try {
        while (true) {
          SSLSocket client = (SSLSocket) listener.accept();
          testHook("accept-return");
          RelayRegistration registration;
          synchronized (registryLock) {
            if (stopping) {
              close(client);
              continue;
            }
            registration = new RelayRegistration(client);
            relays.add(registration);
          }
          testHook("relay-registered");
          synchronized (registryLock) {
            if (stopping) {
              registration.close();
              relays.remove(registration);
              continue;
            }
          }
          registration.thread = Thread.ofVirtual().start(() -> {
            try {
              relay(client, config, registration);
            } catch (Exception ignored) {
              close(client);
            } finally {
              registration.close();
              try {
                testHook("relay-removal");
              } catch (IOException ignored) {
                // The disabled production hook cannot affect relay cleanup.
              }
              synchronized (registryLock) {
                relays.remove(registration);
              }
            }
          });
        }
      } catch (IOException ignored) {
        // Closing the admission listener is the committed stop gate.
      }
    }

    private void quiesce() throws IOException {
      List<RelayRegistration> snapshot;
      Thread accept;
      synchronized (registryLock) {
        stopping = true;
        close(listener);
        snapshot = List.copyOf(relays);
        accept = acceptThread;
      }
      if (accept != null) {
        join(accept, "public accept loop");
      }
      for (RelayRegistration relay : snapshot) {
        relay.close();
      }
      for (RelayRegistration relay : snapshot) {
        if (relay.thread != null) {
          join(relay.thread, "public relay");
        }
      }
      synchronized (registryLock) {
        if (!relays.isEmpty()) {
          throw new IOException("public relay registry did not quiesce");
        }
      }
    }

    private static void join(Thread thread, String role) throws IOException {
      try {
        thread.join(Duration.ofSeconds(3));
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
        throw new IOException("interrupted while joining " + role, interrupted);
      }
      if (thread.isAlive()) {
        throw new IOException(role + " did not quiesce");
      }
    }

    private final class RelayRegistration {
      private final SSLSocket client;
      private Socket backend;
      private Thread thread;

      private RelayRegistration(SSLSocket client) {
        this.client = client;
      }

      private boolean registerBackend(Socket candidate) {
        synchronized (registryLock) {
          if (stopping) {
            MkChadTlsProxy.close(candidate);
            return false;
          }
          backend = candidate;
          return true;
        }
      }

      private void close() {
        MkChadTlsProxy.close(client);
        synchronized (registryLock) {
          MkChadTlsProxy.close(backend);
        }
      }
    }
  }

  private static BrokerConfig parseBroker(String[] args) {
    Map<String, String> values = parseOptions(args);
    String adoptedPid = values.get("--adopt-backend-pid");
    String adoptedStart = values.get("--adopt-backend-start");
    if ((adoptedPid == null) != (adoptedStart == null) || values.size() != (adoptedPid == null ? 14 : 16)) {
      throw new IllegalArgumentException("invalid broker argument count");
    }
    Path stateRoot = Path.of(required(values, "--state-root"));
    Path control = Path.of(required(values, "--control"));
    if (!stateRoot.isAbsolute() || !control.isAbsolute() || !control.getParent().equals(stateRoot)) {
      throw new IllegalArgumentException("broker state paths must be absolute direct children");
    }
    String generation = required(values, "--generation");
    String bootId = required(values, "--boot-id");
    String backendVersion = required(values, "--backend-version");
    if (!safeToken(generation, 256) || !safeToken(bootId, 64) || !safeText(backendVersion, 128)) {
      throw new IllegalArgumentException("broker generation, boot identity, or backend version is invalid");
    }
    int maxConnections = Integer.parseInt(required(values, "--max-connections"));
    if (maxConnections < 1 || maxConnections > 1024) {
      throw new IllegalArgumentException("invalid proxy bounds");
    }
    Long adoptedBackendPid = adoptedPid == null ? null : Long.parseLong(adoptedPid);
    if (adoptedBackendPid != null
        && (adoptedBackendPid <= 0 || !adoptedStart.matches("[0-9]+"))) {
      throw new IllegalArgumentException("invalid adopted backend identity");
    }
    return new BrokerConfig(
        stateRoot,
        control,
        generation,
        bootId,
        Path.of(required(values, "--backend-executable")),
        backendVersion,
        port(values, "--backend-port"),
        port(values, "--listen-port"),
        Path.of(required(values, "--keystore")),
        Path.of(required(values, "--password-file")),
        maxConnections,
        Path.of(required(values, "--backend-log")),
        Path.of(required(values, "--pidfd-python")),
        Path.of(required(values, "--pidfd-helper")),
        adoptedBackendPid,
        adoptedStart);
  }

  private static Config parse(String[] args) {
    Map<String, String> values = parseOptions(args);
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

  private static Map<String, String> parseOptions(String[] args) {
    Map<String, String> values = new HashMap<>();
    for (int i = 0; i < args.length; i += 2) {
      if (i + 1 >= args.length || !args[i].startsWith("--") || values.put(args[i], args[i + 1]) != null) {
        throw new IllegalArgumentException("invalid or duplicate proxy argument");
      }
    }
    return values;
  }

  private static void runBroker(BrokerConfig config) throws Exception {
    FileIdentity root = requirePrivateDirectory(config.stateRoot());
    if (Files.exists(config.control(), LinkOption.NOFOLLOW_LINKS)) {
      throw new IOException("control socket already exists");
    }
    requireRegularFile(config.backendExecutable());
    requirePrivateRegularFile(config.keyStore());
    requirePrivateRegularFile(config.passwordFile());
    requirePrivateRegularFile(config.backendLog());
    requireRegularFile(config.pidfdPython());
    requireRegularFile(config.pidfdHelper());
    BrokerAuthority authority = captureBrokerAuthority(config);
    AtomicReference<BrokerPhase> phase = new AtomicReference<>(BrokerPhase.CONTROL_READY);
    AtomicReference<ProcessHandle> backend = new AtomicReference<>();
    AtomicReference<BrokerTlsService> service = new AtomicReference<>();
    AtomicBoolean activationInFlight = new AtomicBoolean();
    CountDownLatch activationDone = new CountDownLatch(1);
    CountDownLatch terminalReceiptWritten = new CountDownLatch(1);
    AtomicReference<ServerSocketChannel> controlListener = new AtomicReference<>();
    ThreadPoolExecutor workers = new ThreadPoolExecutor(
        CONTROL_CONNECTION_LIMIT,
        CONTROL_CONNECTION_LIMIT,
        0L,
        TimeUnit.MILLISECONDS,
        new ArrayBlockingQueue<>(CONTROL_QUEUE_LIMIT),
        new ThreadPoolExecutor.AbortPolicy());
    try (ServerSocketChannel listener = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
      controlListener.set(listener);
      listener.bind(UnixDomainSocketAddress.of(config.control()));
      setPrivateMode(config.control(), false);
      FileIdentity control = requirePrivateSocket(config.control());
      if (!root.equals(requirePrivateDirectory(config.stateRoot()))) {
        throw new IOException("state root changed while binding control socket");
      }
      while (phase.get() != BrokerPhase.STOPPED) {
        SocketChannel channel;
        try {
          channel = listener.accept();
        } catch (IOException closed) {
          if (phase.get() == BrokerPhase.STOPPING || phase.get() == BrokerPhase.STOPPED) {
            break;
          }
          throw closed;
        }
        try {
          workers.execute(() -> handleControl(
              channel,
              config,
              authority,
              root,
              control,
              phase,
              backend,
              service,
              activationInFlight,
              activationDone,
              controlListener,
              terminalReceiptWritten));
        } catch (RuntimeException rejected) {
          close(channel);
        }
      }
      if (phase.get() == BrokerPhase.STOPPING || phase.get() == BrokerPhase.STOPPED) {
        terminalReceiptWritten.await(CONTROL_DEADLINE_NANOS, TimeUnit.NANOSECONDS);
      }
    } finally {
      workers.shutdownNow();
    }
  }

  private static void handleControl(
      SocketChannel channel,
      BrokerConfig config,
      BrokerAuthority authority,
      FileIdentity root,
      FileIdentity control,
      AtomicReference<BrokerPhase> phase,
      AtomicReference<ProcessHandle> backend,
      AtomicReference<BrokerTlsService> service,
      AtomicBoolean activationInFlight,
      CountDownLatch activationDone,
      AtomicReference<ServerSocketChannel> controlListener,
      CountDownLatch terminalReceiptWritten) {
    try (channel) {
      channel.configureBlocking(false);
      long deadline = System.nanoTime() + CONTROL_DEADLINE_NANOS;
      ControlRequest request = readControlRequest(channel, deadline);
      if (!request.generation().equals(config.generation())) {
        return;
      }
      // A complete request must still name the original private authority at commit time.
      if (!root.equals(requirePrivateDirectory(config.stateRoot()))
          || !control.equals(requirePrivateSocket(config.control()))) {
        return;
      }
      requireBrokerSelf(config, authority, phase.get() == BrokerPhase.RUNNING);
      BrokerPhase current = phase.get();
      if (request.operation().equals("activate")
          && current == BrokerPhase.CONTROL_READY
          && phase.compareAndSet(BrokerPhase.CONTROL_READY, BrokerPhase.ACTIVATING)) {
        activationInFlight.set(true);
        Thread.ofVirtual().start(() -> activateBroker(
            config, authority, phase, backend, service, activationInFlight, activationDone));
        try {
          activationDone.await(Math.max(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
        } catch (InterruptedException interrupted) {
          Thread.currentThread().interrupt();
          return;
        }
        current = BrokerPhase.ACTIVATING;
      } else if (request.operation().equals("stop") && beginStop(phase)) {
        boolean terminateManagedBackend = config.adoptedBackendPid() == null || current == BrokerPhase.RUNNING;
        completeStop(
            config,
            authority,
            root,
            control,
            phase,
            backend,
            service,
            activationInFlight,
            activationDone,
            controlListener,
            request,
            channel,
            terminateManagedBackend,
            terminalReceiptWritten);
        return;
      }
      String response = controlResponse(
          request, current == BrokerPhase.STOPPING ? current : phase.get(), config, authority, control, backend.get());
      writeControlResponse(channel, response, deadline);
    } catch (IOException ignored) {
      // Invalid, incomplete, and overloaded exchanges are deliberately non-mutating.
    }
  }

  private static boolean beginStop(AtomicReference<BrokerPhase> phase) {
    while (true) {
      BrokerPhase current = phase.get();
      if (current == BrokerPhase.STOPPING || current == BrokerPhase.STOPPED) {
        return false;
      }
      if (!Set.of(BrokerPhase.CONTROL_READY, BrokerPhase.ACTIVATING, BrokerPhase.ACTIVATION_FAILED,
          BrokerPhase.RUNNING, BrokerPhase.UNHEALTHY, BrokerPhase.BLOCKED).contains(current)) {
        return false;
      }
      if (phase.compareAndSet(current, BrokerPhase.STOPPING)) {
        return true;
      }
    }
  }

  private static BrokerAuthority captureBrokerAuthority(BrokerConfig config) throws IOException {
    long pid = ProcessHandle.current().pid();
    Path proc = Path.of("/proc", Long.toString(pid));
    List<String> argv = List.copyOf(procArgv(proc.resolve("cmdline")));
    int sourceOption = argv.indexOf("--source");
    int brokerOption = argv.indexOf("--broker");
    if (sourceOption < 1
        || sourceOption + 3 != brokerOption
        || !"21".equals(argv.get(sourceOption + 1))
        || !argv.subList(brokerOption, argv.size()).equals(expectedBrokerTail(config))) {
      throw new IOException("broker source-mode argv is invalid");
    }
    Path launchPath = Path.of(argv.getFirst());
    Path source = Path.of(argv.get(sourceOption + 2));
    if (!launchPath.isAbsolute() || !source.isAbsolute()) {
      throw new IOException("broker runtime and source paths must be absolute");
    }
    BrokerAuthority authority = new BrokerAuthority(
        pid,
        processStart(proc.resolve("stat")),
        Path.of(Files.readSymbolicLink(proc.resolve("exe")).toString().replaceFirst(" \\(deleted\\)$", "")),
        fileIdentity(proc.resolve("exe")),
        launchPath,
        fileIdentity(launchPath),
        argv,
        source,
        fileIdentity(source),
        fileIdentity(config.backendExecutable()),
        fileIdentity(config.pidfdPython()),
        fileIdentity(config.pidfdHelper()));
    requireBrokerSelf(config, authority, false);
    return authority;
  }

  private static List<String> expectedBrokerTail(BrokerConfig config) {
    List<String> arguments = new ArrayList<>(List.of(
        "--broker",
        "--state-root", config.stateRoot().toString(),
        "--control", config.control().toString(),
        "--generation", config.generation(),
        "--boot-id", config.bootId(),
        "--backend-executable", config.backendExecutable().toString(),
        "--backend-version", config.backendVersion(),
        "--backend-port", Integer.toString(config.backendPort()),
        "--listen-port", Integer.toString(config.listenPort()),
        "--keystore", config.keyStore().toString(),
        "--password-file", config.passwordFile().toString(),
        "--max-connections", Integer.toString(config.maxConnections()),
        "--backend-log", config.backendLog().toString(),
        "--pidfd-python", config.pidfdPython().toString(),
        "--pidfd-helper", config.pidfdHelper().toString()));
    if (config.adoptedBackendPid() != null) {
      arguments.add("--adopt-backend-pid");
      arguments.add(Long.toString(config.adoptedBackendPid()));
      arguments.add("--adopt-backend-start");
      arguments.add(config.adoptedBackendStart());
    }
    return List.copyOf(arguments);
  }

  private static void requireBrokerSelf(BrokerConfig config, BrokerAuthority authority, boolean requireListener)
      throws IOException {
    Path proc = Path.of("/proc", Long.toString(authority.pid()));
    List<String> argv = procArgv(proc.resolve("cmdline"));
    boolean listenerOwned = !requireListener || ownsUniqueListener(config.listenPort(), authority.pid());
    validateBrokerSelfEvidenceForTest(authority.argv(), argv, listenerOwned);
    if (ProcessHandle.current().pid() != authority.pid()
        || !Files.readString(Path.of("/proc/sys/kernel/random/boot_id"), StandardCharsets.US_ASCII).trim()
            .equals(config.bootId())
        || !processStart(proc.resolve("stat")).equals(authority.start())
        || !Path.of(Files.readSymbolicLink(proc.resolve("exe")).toString().replaceFirst(" \\(deleted\\)$", ""))
            .equals(authority.runtimePath())
        || !fileIdentity(proc.resolve("exe")).equals(authority.runtime())
        || !fileIdentity(authority.launchPath()).equals(authority.launch())
        || !fileIdentity(authority.source()).equals(authority.sourceIdentity())
        || !fileIdentity(config.backendExecutable()).equals(authority.backendExecutable())
        || !fileIdentity(config.pidfdPython()).equals(authority.pidfdPython())
        || !fileIdentity(config.pidfdHelper()).equals(authority.pidfdHelper())) {
      throw new IOException("broker self or frozen asset identity changed");
    }
  }

  static void validateBrokerSelfEvidenceForTest(
      List<String> expectedArgv, List<String> actualArgv, boolean listenerOwned) throws IOException {
    if (!expectedArgv.equals(actualArgv) || !listenerOwned) {
      throw new IOException("broker full argv or listener identity changed");
    }
  }

  static void validateFrozenIdentityForTest(
      long expectedDevice, long expectedInode, long actualDevice, long actualInode) throws IOException {
    if (expectedDevice != actualDevice || expectedInode != actualInode) {
      throw new IOException("frozen lifecycle asset identity changed");
    }
  }

  private static void activateBroker(
      BrokerConfig config,
      BrokerAuthority authority,
      AtomicReference<BrokerPhase> phase,
      AtomicReference<ProcessHandle> backend,
      AtomicReference<BrokerTlsService> service,
      AtomicBoolean activationInFlight,
      CountDownLatch activationDone) {
    try {
      if (phase.get() != BrokerPhase.ACTIVATING) {
        return;
      }
      ProcessHandle started;
      String backendStart;
      boolean adopting = config.adoptedBackendPid() != null;
      if (adopting) {
        started = ProcessHandle.of(config.adoptedBackendPid())
            .filter(ProcessHandle::isAlive)
            .orElseThrow(() -> new IOException("adopted backend is not live"));
        backendStart = processStart(Path.of("/proc", Long.toString(started.pid()), "stat"));
        if (!backendStart.equals(config.adoptedBackendStart())) {
          throw new IOException("adopted backend start identity changed");
        }
      } else {
        Process child = new ProcessBuilder(
            config.backendExecutable().toString(), "serve", "--hostname", "127.0.0.1", "--port",
            Integer.toString(config.backendPort()))
            .redirectInput(ProcessBuilder.Redirect.from(Path.of("/dev/null").toFile()))
            .redirectOutput(ProcessBuilder.Redirect.appendTo(config.backendLog().toFile()))
            .redirectError(ProcessBuilder.Redirect.appendTo(config.backendLog().toFile()))
            .start();
        started = child.toHandle();
        backendStart = processStart(Path.of("/proc", Long.toString(started.pid()), "stat"));
      }
      backend.set(started);
      Config tls = new Config(config.listenPort(), config.backendPort(), started.pid(), backendStart, config.bootId(),
          config.keyStore(), config.passwordFile(), config.maxConnections());
      requireLinuxEvidence(tls);
      waitForListener(tls, System.nanoTime() + CONTROL_DEADLINE_NANOS);
      if (phase.get() != BrokerPhase.ACTIVATING) {
        return;
      }
      BrokerTlsService startedService = new BrokerTlsService(tls);
      service.set(startedService);
      startedService.start();
      waitForOwnedListener(tls.listenPort(), ProcessHandle.current().pid(), System.nanoTime() + CONTROL_DEADLINE_NANOS);
      phase.compareAndSet(BrokerPhase.ACTIVATING, BrokerPhase.RUNNING);
    } catch (Exception failure) {
      if (phase.get() == BrokerPhase.ACTIVATING) {
        boolean adopting = config.adoptedBackendPid() != null;
        boolean cleaned = cleanupFailedActivation(config, authority, backend.get(), service.get(), !adopting);
        if (cleaned && adopting) {
          backend.set(null);
        }
        phase.compareAndSet(
            BrokerPhase.ACTIVATING, cleaned ? BrokerPhase.ACTIVATION_FAILED : BrokerPhase.BLOCKED);
      }
    } finally {
      activationInFlight.set(false);
      activationDone.countDown();
    }
  }

  private static boolean cleanupFailedActivation(
      BrokerConfig config,
      BrokerAuthority authority,
      ProcessHandle backend,
      BrokerTlsService service,
      boolean terminateBackend) {
    try {
      if (service != null) {
        service.quiesce();
      }
      if (terminateBackend && backend != null && backend.isAlive()) {
        terminateBackend(backend, config, authority, false, System.nanoTime() + CONTROL_DEADLINE_NANOS);
      }
      return !terminateBackend || backend == null || !backend.isAlive();
    } catch (Exception failure) {
      return false;
    }
  }

  private static void completeStop(
      BrokerConfig config,
      BrokerAuthority authority,
      FileIdentity root,
      FileIdentity control,
      AtomicReference<BrokerPhase> phase,
      AtomicReference<ProcessHandle> backend,
      AtomicReference<BrokerTlsService> service,
      AtomicBoolean activationInFlight,
      CountDownLatch activationDone,
      AtomicReference<ServerSocketChannel> controlListener,
      ControlRequest request,
      SocketChannel channel,
      boolean terminateManagedBackend,
      CountDownLatch terminalReceiptWritten) {
    try {
      BrokerTlsService publicService = service.get();
      if (publicService != null) {
        publicService.quiesce();
      }
      if (activationInFlight.get()
          && !activationDone.await(CONTROL_DEADLINE_NANOS, TimeUnit.NANOSECONDS)) {
        return;
      }
      publicService = service.get();
      if (publicService != null) {
        publicService.quiesce();
      }
      ProcessHandle child = backend.get();
      if (terminateManagedBackend && child != null && child.isAlive()) {
        terminateBackend(
            child, config, authority, publicService != null, System.nanoTime() + CONTROL_DEADLINE_NANOS);
      }
      if (terminateManagedBackend && child != null && child.isAlive()) {
        return;
      }
      if (!root.equals(requirePrivateDirectory(config.stateRoot()))
          || !control.equals(requirePrivateSocket(config.control()))) {
        return;
      }
      close(controlListener.get());
      if (!Files.deleteIfExists(config.control())) {
        return;
      }
      phase.set(BrokerPhase.STOPPED);
      writeControlResponse(channel, controlResponse(request, BrokerPhase.STOPPED, config, authority, control, child),
          System.nanoTime() + CONTROL_DEADLINE_NANOS);
    } catch (Exception ignored) {
      // A committed stop leaves authority intact unless all terminal proof succeeds.
    } finally {
      terminalReceiptWritten.countDown();
    }
  }

  private static void terminateBackend(
      ProcessHandle backend, BrokerConfig config, BrokerAuthority authority, boolean requireListener, long deadline)
      throws IOException {
    invokePidfdHelper(
        backendReceipt(backend.pid(), config, authority, requireListener), config, authority, "SIGTERM", deadline);
    long killAt = Math.min(deadline, System.nanoTime() + PIDFD_TERM_GRACE_NANOS);
    while (backend.isAlive() && System.nanoTime() < killAt) {
      sleepBriefly();
    }
    if (backend.isAlive()) {
      invokePidfdHelper(
          backendReceipt(backend.pid(), config, authority, requireListener), config, authority, "SIGKILL", deadline);
      while (backend.isAlive() && System.nanoTime() < deadline) {
        sleepBriefly();
      }
    }
    if (backend.isAlive()) {
      throw new IOException("backend did not exit after pidfd signal");
    }
  }

  private static void invokePidfdHelper(
      String backend, BrokerConfig config, BrokerAuthority authority, String signal, long deadline) throws IOException {
    if (System.nanoTime() >= deadline) {
      throw new IOException("pidfd signal helper timed out");
    }
    String request = "{\"schema\":1,\"boot_id\":\"" + json(config.bootId()) + "\",\"signal\":\""
        + signal + "\",\"process\":" + backend + "}";
    requireBrokerSelf(config, authority, false);
    testHook("pidfd-signal");
    Process helper = new ProcessBuilder(config.pidfdPython().toString(), config.pidfdHelper().toString()).start();
    AtomicReference<byte[]> stderr = new AtomicReference<>(new byte[0]);
    AtomicReference<IOException> streamFailure = new AtomicReference<>();
    CountDownLatch streamsDone = new CountDownLatch(2);
    Thread.ofVirtual().start(() -> {
      try {
        stderr.set(readBounded(helper.getErrorStream()));
      } catch (IOException failure) {
        streamFailure.compareAndSet(null, failure);
      } finally {
        streamsDone.countDown();
      }
    });
    Thread.ofVirtual().start(() -> {
      try {
        readBounded(helper.getInputStream());
      } catch (IOException failure) {
        streamFailure.compareAndSet(null, failure);
      } finally {
        streamsDone.countDown();
      }
    });
    try {
      try (OutputStream input = helper.getOutputStream()) {
        input.write(request.getBytes(StandardCharsets.UTF_8));
      }
      long remaining = deadline - System.nanoTime();
      if (remaining <= 0 || !helper.waitFor(remaining, TimeUnit.NANOSECONDS)) {
        helper.destroy();
        if (!helper.waitFor(PIDFD_TERM_GRACE_NANOS, TimeUnit.NANOSECONDS)) {
          helper.destroyForcibly();
          helper.waitFor();
        }
        throw new IOException("pidfd signal helper timed out");
      }
      if (!streamsDone.await(Math.max(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS)) {
        throw new IOException("pidfd signal helper streams did not close");
      }
      if (streamFailure.get() != null) {
        throw streamFailure.get();
      }
      if (helper.exitValue() != 0) {
        String detail = new String(stderr.get(), StandardCharsets.UTF_8).trim();
        throw new IOException(detail.isEmpty() ? "pidfd signal helper refused the managed process" : detail);
      }
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
      throw new IOException("interrupted while waiting for pidfd signal helper", interrupted);
    } finally {
      helper.destroyForcibly();
    }
  }

  private static byte[] readBounded(InputStream input) throws IOException {
    ByteArrayOutputStream output = new ByteArrayOutputStream();
    byte[] buffer = new byte[4096];
    for (int count; (count = input.read(buffer)) >= 0; ) {
      if (output.size() + count > HELPER_OUTPUT_LIMIT) {
        throw new IOException("pidfd signal helper output exceeded its bound");
      }
      output.write(buffer, 0, count);
    }
    return output.toByteArray();
  }

  /** Test-only deterministic scheduling hook. It is inert without an explicit JVM property. */
  private static void testHook(String name) throws IOException {
    String directory = System.getProperty("mkchad.proxy.test-hook-dir");
    if (directory == null || directory.isEmpty()) {
      return;
    }
    Path root = Path.of(directory);
    if (!Files.isRegularFile(root.resolve(name + ".enabled"), LinkOption.NOFOLLOW_LINKS)) {
      return;
    }
    Path reached = root.resolve(name + ".reached");
    Path resume = root.resolve(name + ".resume");
    Files.writeString(reached, "reached\n", StandardCharsets.US_ASCII);
    long deadline = System.nanoTime() + CONTROL_DEADLINE_NANOS;
    while (!Files.isRegularFile(resume, LinkOption.NOFOLLOW_LINKS)) {
      if (System.nanoTime() >= deadline) {
        throw new IOException("test hook timed out: " + name);
      }
      sleepBriefly();
    }
  }

  private static void sleepBriefly() throws IOException {
    try {
      Thread.sleep(10);
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
      throw new IOException("interrupted while waiting for backend exit", interrupted);
    }
  }

  private static void waitForListener(Config config, long deadline) throws IOException {
    while (System.nanoTime() < deadline) {
      requireLinuxEvidence(config);
      String inode = findUniqueListenerInode(config.backendPort());
      if (inode != null && ownsInode(config.backendPid(), inode)) {
        return;
      }
      try {
        Thread.sleep(20);
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
        throw new IOException("interrupted while waiting for backend listener", interrupted);
      }
    }
    throw new IOException("backend did not acquire its expected loopback listener");
  }

  private static String findUniqueListenerInode(int port) {
    try {
      String wanted = "%04X".formatted(port);
      List<String> matches = new ArrayList<>();
      for (Path table : List.of(Path.of("/proc/net/tcp"), Path.of("/proc/net/tcp6"))) {
        List<String> lines = Files.readAllLines(table, StandardCharsets.US_ASCII);
        if (lines.size() > PROC_ENTRY_LIMIT) {
          return null;
        }
        for (int index = 1; index < lines.size(); index++) {
          String[] fields = WHITESPACE.split(lines.get(index).trim());
          if (fields.length >= 10 && fields[1].endsWith(":" + wanted) && fields[3].equals("0A")) {
            matches.add(fields[9]);
          }
        }
      }
      return matches.size() == 1 ? matches.getFirst() : null;
    } catch (IOException ignored) {
      return null;
    }
  }

  private static void waitForOwnedListener(int port, long pid, long deadline) throws IOException {
    while (System.nanoTime() < deadline) {
      String inode = findUniqueListenerInode(port);
      if (inode != null && ownsInode(pid, inode)) {
        return;
      }
      try {
        Thread.sleep(20);
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
        throw new IOException("interrupted while waiting for broker listener", interrupted);
      }
    }
    throw new IOException("broker did not acquire its expected loopback listener");
  }

  private static boolean ownsUniqueListener(int port, long pid) throws IOException {
    String inode = findUniqueListenerInode(port);
    return inode != null && ownsInode(pid, inode);
  }

  private static String required(Map<String, String> values, String key) {
    String value = values.get(key);
    if (value == null || value.isEmpty()) {
      throw new IllegalArgumentException("missing " + key);
    }
    return value;
  }

  private record FileIdentity(long device, long inode) {}

  private static FileIdentity requirePrivateDirectory(Path path) throws IOException {
    if (!path.isAbsolute()) {
      throw new IOException("state root is not absolute");
    }
    Path current = path.getRoot();
    for (Path component : path) {
      current = current.resolve(component);
      if (Files.isSymbolicLink(current)) {
        throw new IOException("authority directory is a symlink");
      }
    }
    if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
      throw new IOException("authority directory is missing or not a directory");
    }
    return requirePrivate(path, true);
  }

  private static FileIdentity requirePrivateSocket(Path path) throws IOException {
    if (Files.isSymbolicLink(path) || !"socket".equals(socketType(path))) {
      throw new IOException("control path is not a socket");
    }
    return requirePrivate(path, false);
  }

  private static String socketType(Path path) throws IOException {
    int mode = (Integer) Files.getAttribute(path, "unix:mode", LinkOption.NOFOLLOW_LINKS);
    return (mode & 0170000) == 0140000 ? "socket" : "";
  }

  private static void requireRegularFile(Path path) throws IOException {
    if (Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
      throw new IOException("broker authority file is missing or unsafe");
    }
  }

  private static void requirePrivateRegularFile(Path path) throws IOException {
    requireRegularFile(path);
    requirePrivate(path, false);
  }

  private static FileIdentity requirePrivate(Path path, boolean directory) throws IOException {
    int mode = (Integer) Files.getAttribute(path, "unix:mode", LinkOption.NOFOLLOW_LINKS);
    long owner = ((Number) Files.getAttribute(path, "unix:uid", LinkOption.NOFOLLOW_LINKS)).longValue();
    long current = currentEffectiveUid();
    int expected = directory ? 0700 : 0600;
    if ((mode & 0777) != expected || owner != current) {
      throw new IOException("authority path ownership or mode is unsafe");
    }
    return new FileIdentity(
        ((Number) Files.getAttribute(path, "unix:dev", LinkOption.NOFOLLOW_LINKS)).longValue(),
        ((Number) Files.getAttribute(path, "unix:ino", LinkOption.NOFOLLOW_LINKS)).longValue());
  }

  private static long currentEffectiveUid() throws IOException {
    String status = Files.readString(Path.of("/proc/self/status"), StandardCharsets.US_ASCII);
    for (String line : status.split("\\n")) {
      if (line.startsWith("Uid:")) {
        String[] fields = WHITESPACE.split(line.substring(4).trim());
        if (fields.length >= 2 && fields[1].matches("[0-9]+")) {
          return Long.parseLong(fields[1]);
        }
      }
    }
    throw new IOException("unable to determine the effective Unix user identity");
  }

  private static void setPrivateMode(Path path, boolean directory) throws IOException {
    Files.setPosixFilePermissions(path, PosixFilePermissions.fromString(directory ? "rwx------" : "rw-------"));
  }

  static void validateControlFrameForTest(byte[] frame) throws IOException {
    decodeControlFrame(frame);
  }

  private static ControlRequest readControlRequest(SocketChannel channel, long deadline) throws IOException {
    byte[] length = readExact(channel, 4, deadline);
    int size = ByteBuffer.wrap(length).getInt();
    if (size < 2 || size > CONTROL_FRAME_LIMIT) {
      throw new IOException("control frame length is invalid");
    }
    byte[] body = readExact(channel, size, deadline);
    byte[] trailing = readAtMostOne(channel, deadline);
    if (trailing != null) {
      throw new IOException("control frame has trailing bytes");
    }
    return decodeControlFrame(concat(length, body));
  }

  private static ControlRequest decodeControlFrame(byte[] frame) throws IOException {
    if (frame.length < 6) {
      throw new IOException("control frame is truncated");
    }
    int size = ByteBuffer.wrap(frame, 0, 4).getInt();
    if (size < 2 || size > CONTROL_FRAME_LIMIT || frame.length != size + 4) {
      throw new IOException("control frame length is invalid");
    }
    String json = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
        .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(frame, 4, size)).toString();
    Map<String, String> values = parseFlatJson(json);
    if (!values.keySet().equals(Set.of("protocol", "operation", "generation", "nonce"))
        || !"1".equals(values.get("protocol"))
        || !Set.of("activate", "status", "stop").contains(values.get("operation"))
        || !safeToken(values.get("generation"), 256)
        || !safeToken(values.get("nonce"), 256)) {
      throw new IOException("control request schema is invalid");
    }
    return new ControlRequest(values.get("operation"), values.get("generation"), values.get("nonce"));
  }

  private static Map<String, String> parseFlatJson(String json) throws IOException {
    if (json.length() < 2 || json.charAt(0) != '{' || json.charAt(json.length() - 1) != '}') {
      throw new IOException("control JSON must be one object");
    }
    Map<String, String> result = new LinkedHashMap<>();
    int index = 1;
    while (index < json.length() - 1) {
      if (json.charAt(index) != '"') {
        throw new IOException("control JSON key is invalid");
      }
      int keyEnd = json.indexOf('"', index + 1);
      int keyEscape = json.indexOf('\\', index + 1);
      if (keyEnd < 0 || keyEnd == index + 1 || (keyEscape >= index + 1 && keyEscape < keyEnd)) {
        throw new IOException("control JSON key is invalid");
      }
      String key = json.substring(index + 1, keyEnd);
      index = keyEnd + 1;
      if (index >= json.length() || json.charAt(index++) != ':') {
        throw new IOException("control JSON separator is invalid");
      }
      String value;
      if (index < json.length() && json.charAt(index) == '"') {
        int valueEnd = json.indexOf('"', index + 1);
        int valueEscape = json.indexOf('\\', index + 1);
        if (valueEnd < 0 || (valueEscape >= index + 1 && valueEscape < valueEnd)) {
          throw new IOException("control JSON value is invalid");
        }
        value = json.substring(index + 1, valueEnd);
        index = valueEnd + 1;
      } else {
        int valueEnd = index;
        while (valueEnd < json.length() - 1 && Character.isDigit(json.charAt(valueEnd))) {
          valueEnd++;
        }
        if (valueEnd == index) {
          throw new IOException("control JSON value is invalid");
        }
        value = json.substring(index, valueEnd);
        index = valueEnd;
      }
      if (result.put(key, value) != null) {
        throw new IOException("control JSON has duplicate fields");
      }
      if (index == json.length() - 1) {
        break;
      }
      if (json.charAt(index++) != ',') {
        throw new IOException("control JSON has trailing content");
      }
    }
    return result;
  }

  private static boolean safeToken(String value, int maximum) {
    return value != null && value.length() > 0 && value.length() <= maximum && value.matches("[A-Za-z0-9_.+\\-]+") ;
  }

  private static boolean safeText(String value, int maximum) {
    return value != null && value.length() > 0 && value.length() <= maximum && value.chars().allMatch(c -> c >= 0x20 && c <= 0x7e);
  }

  private static byte[] readExact(SocketChannel channel, int length, long deadline) throws IOException {
    ByteBuffer buffer = ByteBuffer.allocate(length);
    while (buffer.hasRemaining()) {
      if (System.nanoTime() >= deadline) {
        throw new IOException("control exchange timed out");
      }
      int count = channel.read(buffer);
      if (count < 0) {
        throw new IOException("control frame is incomplete");
      }
    }
    return buffer.array();
  }

  private static byte[] readAtMostOne(SocketChannel channel, long deadline) throws IOException {
    ByteBuffer byteBuffer = ByteBuffer.allocate(1);
    while (System.nanoTime() < deadline) {
      int count = channel.read(byteBuffer);
      if (count < 0) {
        return null;
      }
      if (count > 0) {
        return byteBuffer.array();
      }
      try {
        Thread.sleep(1);
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
        throw new IOException("interrupted while waiting for control EOF", interrupted);
      }
    }
    throw new IOException("control exchange did not half-close");
  }

  private static void writeControlResponse(SocketChannel channel, String json, long deadline) throws IOException {
    byte[] body = json.getBytes(StandardCharsets.UTF_8);
    if (body.length > CONTROL_FRAME_LIMIT) {
      throw new IOException("control response exceeds its bound");
    }
    ByteBuffer frame = ByteBuffer.allocate(body.length + 4).putInt(body.length).put(body);
    frame.flip();
    while (frame.hasRemaining()) {
      if (System.nanoTime() >= deadline || channel.write(frame) < 0) {
        throw new IOException("control response write failed");
      }
    }
  }

  private static byte[] concat(byte[] first, byte[] second) {
    byte[] result = Arrays.copyOf(first, first.length + second.length);
    System.arraycopy(second, 0, result, first.length, second.length);
    return result;
  }

  private static String controlResponse(
      ControlRequest request,
      BrokerPhase phase,
      BrokerConfig config,
      BrokerAuthority authority,
      FileIdentity control,
      ProcessHandle backend) {
    BrokerPhase responsePhase = phase;
    String backendReceipt = null;
    String error = null;
    if (phase == BrokerPhase.RUNNING && backend != null) {
      try {
        requireBrokerSelf(config, authority, true);
        backendReceipt = backendReceipt(backend.pid(), config, authority, true);
      } catch (IOException failure) {
        // The broker remains live, but its recorded child is no longer exact.
        responsePhase = BrokerPhase.UNHEALTHY;
        error = "backend-evidence-lost";
      }
    }
    StringBuilder response = new StringBuilder("{")
        .append("\"protocol\":1,\"operation\":\"").append(request.operation())
        .append("\",\"generation\":\"").append(config.generation())
        .append("\",\"nonce\":\"").append(request.nonce())
        .append("\",\"phase\":\"").append(responsePhase.wire).append("\",")
        .append("\"control\":{\"path\":\"").append(json(config.control().toString()))
        .append("\",\"dev\":\"").append(unsignedIdentityForTest(control.device()))
        .append("\",\"ino\":\"").append(unsignedIdentityForTest(control.inode())).append("\"}")
        .append(",\"proxy\":").append(proxyReceipt(config, authority));
    if (backendReceipt != null) {
      response.append(",\"backend\":").append(backendReceipt);
    } else if (error != null) {
      response.append(",\"error\":\"").append(error).append("\"");
    } else if (responsePhase == BrokerPhase.ACTIVATION_FAILED || responsePhase == BrokerPhase.BLOCKED) {
      response.append(",\"error\":\"")
          .append(phase == BrokerPhase.BLOCKED ? "blocked" : "activation-failed")
          .append("\"");
    }
    return response.append('}').toString();
  }

  private static String proxyReceipt(BrokerConfig config, BrokerAuthority authority) {
    StringBuilder value = new StringBuilder("{")
        .append("\"pid\":").append(authority.pid())
        .append(",\"port\":").append(config.listenPort())
        .append(",\"argv\":[");
    appendJsonArray(value, authority.argv());
    return value.append("],\"process_executable\":\"").append(json(authority.runtimePath().toString()))
        .append("\",\"process_executable_dev\":\"").append(unsignedIdentityForTest(authority.runtime().device()))
        .append("\",\"process_executable_ino\":\"").append(unsignedIdentityForTest(authority.runtime().inode()))
        .append("\",\"executable\":\"").append(json(authority.launchPath().toString()))
        .append("\",\"executable_dev\":\"").append(unsignedIdentityForTest(authority.launch().device()))
        .append("\",\"executable_ino\":\"").append(unsignedIdentityForTest(authority.launch().inode()))
        .append("\",\"start_time\":\"").append(authority.start())
        .append("\",\"source\":\"").append(json(authority.source().toString()))
        .append("\",\"source_dev\":\"").append(unsignedIdentityForTest(authority.sourceIdentity().device()))
        .append("\",\"source_ino\":\"").append(unsignedIdentityForTest(authority.sourceIdentity().inode()))
        .append("\"}").toString();
  }

  private static String backendReceipt(
      long pid, BrokerConfig config, BrokerAuthority authority, boolean requireListener) throws IOException {
    Path proc = Path.of("/proc", Long.toString(pid));
    FileIdentity runtime = fileIdentity(proc.resolve("exe"));
    FileIdentity executable = fileIdentity(config.backendExecutable());
    if (!executable.equals(authority.backendExecutable())
        || (requireListener && !ownsUniqueListener(config.backendPort(), pid))) {
      throw new IOException("backend frozen executable or listener identity changed");
    }
    List<String> argv = procArgv(proc.resolve("cmdline"));
    if (argv.isEmpty()) {
      throw new IOException("backend argv is absent");
    }
    StringBuilder value = new StringBuilder("{")
        .append("\"pid\":").append(pid)
        .append(",\"port\":").append(config.backendPort())
        .append(",\"argv\":[");
    appendJsonArray(value, argv);
    return value.append("],\"process_executable\":\"").append(json(Files.readSymbolicLink(proc.resolve("exe")).toString()))
        .append("\",\"process_executable_dev\":\"").append(unsignedIdentityForTest(runtime.device()))
        .append("\",\"process_executable_ino\":\"").append(unsignedIdentityForTest(runtime.inode()))
        .append("\",\"executable\":\"").append(json(config.backendExecutable().toString()))
        .append("\",\"executable_dev\":\"").append(unsignedIdentityForTest(executable.device()))
        .append("\",\"executable_ino\":\"").append(unsignedIdentityForTest(executable.inode()))
        .append("\",\"start_time\":\"").append(processStart(proc.resolve("stat")))
        .append("\",\"local_version\":\"").append(json(config.backendVersion()))
        .append("\",\"log\":\"").append(json(config.backendLog().toString()))
        .append("\"}").toString();
  }

  private static void appendJsonArray(StringBuilder value, List<String> entries) {
    for (int index = 0; index < entries.size(); index++) {
      if (index > 0) {
        value.append(',');
      }
      value.append('"').append(json(entries.get(index))).append('"');
    }
  }

  private static FileIdentity fileIdentity(Path path) throws IOException {
    return new FileIdentity(
        ((Number) Files.getAttribute(path, "unix:dev")).longValue(),
        ((Number) Files.getAttribute(path, "unix:ino")).longValue());
  }

  static String unsignedIdentityForTest(long value) {
    return Long.toUnsignedString(value);
  }

  private static List<String> procArgv(Path path) throws IOException {
    byte[] content = Files.readAllBytes(path);
    List<String> result = new ArrayList<>();
    int start = 0;
    for (int index = 0; index < content.length; index++) {
      if (content[index] == 0) {
        if (index == start) {
          throw new IOException("backend argv is malformed");
        }
        String value = new String(content, start, index - start, StandardCharsets.UTF_8);
        if (!safeText(value, 4096)) {
          throw new IOException("backend argv is unsafe");
        }
        result.add(value);
        start = index + 1;
      }
    }
    if (start != content.length || result.isEmpty() || result.size() > 128) {
      throw new IOException("backend argv is malformed");
    }
    return result;
  }

  private static String json(String value) {
    return value.replace("\\", "\\\\").replace("\"", "\\\"");
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
    relay(client, config, null);
  }

  private static void relay(SSLSocket client, Config config, BrokerTlsService.RelayRegistration registration)
      throws Exception {
    client.setSoTimeout(PROOF_TIMEOUT_MS);
    SSLParameters parameters = client.getSSLParameters();
    parameters.setApplicationProtocols(new String[0]);
    client.setSSLParameters(parameters);
    client.startHandshake();

    // No decrypted client byte is read until this immutable process identity is live.
    requireLinuxEvidence(config);
    try (client; Socket backend = new Socket()) {
      if (registration != null && !registration.registerBackend(backend)) {
        return;
      }
      testHook("backend-connect");
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
      // A queued scan may wait as long as one bounded scan, but never indefinitely.
      acquired = PROOF_SCAN_PERMITS.tryAcquire(PROC_SCAN_TIMEOUT_NANOS, TimeUnit.NANOSECONDS);
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
    boolean shortEntry = state == 3 || state == 6 || (state == 5 && fields.length == 12);
    int expectedFields = shortEntry ? 12 : 17;
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

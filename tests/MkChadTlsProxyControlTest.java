import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** Focused protocol tests for the private broker control frame. */
public final class MkChadTlsProxyControlTest {
  private MkChadTlsProxyControlTest() {}

  public static void main(String[] args) throws Exception {
    valid("activate");
    valid("status");
    valid("stop");

    invalid("{\"protocol\":1,\"operation\":\"status\",\"generation\":\"g\",\"nonce\":\"n\",\"extra\":true}");
    invalid("{\"protocol\":1,\"operation\":\"status\",\"generation\":\"g\",\"nonce\":\"n\",\"nonce\":\"other\"}");
    invalid("{\"protocol\":1,\"operation\":\"launch\",\"generation\":\"g\",\"nonce\":\"n\"}");
    invalid("{\"protocol\":2,\"operation\":\"status\",\"generation\":\"g\",\"nonce\":\"n\"}");
    invalid("{\"protocol\":1,\"operation\":\"status\",\"generation\":\"g\"}");
    invalidBytes(new byte[] {(byte) 0xc3, 0x28});
    invalidFrame(ByteBuffer.allocate(4).putInt(65_537).array());
    invalidFrame(concat(frame("{\"protocol\":1,\"operation\":\"status\",\"generation\":\"g\",\"nonce\":\"n\"}"), new byte[] {0}));
    if (!MkChadTlsProxy.unsignedIdentityForTest(-1L).equals("18446744073709551615")) {
      throw new AssertionError("high-bit Unix identity was not serialized as unsigned decimal");
    }

    List<String> exact = List.of("java", "--source", "21", "/private/proxy.java", "--broker");
    MkChadTlsProxy.validateBrokerSelfEvidenceForTest(exact, exact, true);
    expectFailure(() -> MkChadTlsProxy.validateBrokerSelfEvidenceForTest(
        exact, List.of("java", "--source", "21", "/replaced/proxy.java", "--broker"), true));
    expectFailure(() -> MkChadTlsProxy.validateBrokerSelfEvidenceForTest(exact, exact, false));
    MkChadTlsProxy.validateFrozenIdentityForTest(7L, 11L, 7L, 11L);
    expectFailure(() -> MkChadTlsProxy.validateFrozenIdentityForTest(7L, 11L, 7L, 12L));
  }

  private static void valid(String operation) throws Exception {
    MkChadTlsProxy.validateControlFrameForTest(frame(
        "{\"protocol\":1,\"operation\":\"" + operation + "\",\"generation\":\"g\",\"nonce\":\"n\"}"));
  }

  private static void invalid(String json) throws Exception {
    invalidBytes(json.getBytes(StandardCharsets.UTF_8));
  }

  private static void invalidBytes(byte[] body) throws Exception {
    expectFailure(() -> MkChadTlsProxy.validateControlFrameForTest(frame(body)));
  }

  private static void invalidFrame(byte[] value) throws Exception {
    expectFailure(() -> MkChadTlsProxy.validateControlFrameForTest(value));
  }

  private static byte[] frame(String json) {
    return frame(json.getBytes(StandardCharsets.UTF_8));
  }

  private static byte[] frame(byte[] body) {
    return concat(ByteBuffer.allocate(4).putInt(body.length).array(), body);
  }

  private static byte[] concat(byte[] first, byte[] second) {
    byte[] result = new byte[first.length + second.length];
    System.arraycopy(first, 0, result, 0, first.length);
    System.arraycopy(second, 0, result, first.length, second.length);
    return result;
  }

  private static void expectFailure(Checked action) throws Exception {
    try {
      action.run();
      throw new AssertionError("malformed control frame was accepted");
    } catch (IOException expected) {
      // Closed parsing rejects malformed input before any state transition.
    }
  }

  @FunctionalInterface
  private interface Checked {
    void run() throws Exception;
  }
}

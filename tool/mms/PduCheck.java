import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Reads an MMS PDU with Android's own parser (com.google.android.mms.pdu.PduParser) and says what it found. */
public class PduCheck {
    static String s(Object o) { return o == null ? "null" : (o instanceof byte[] ? new String((byte[]) o) : String.valueOf(o)); }
    static Object call(Object o, String m, Object... a) throws Exception {
        for (Method x : o.getClass().getMethods()) if (x.getName().equals(m) && x.getParameterCount() == a.length) return x.invoke(o, a);
        throw new NoSuchMethodException(m);
    }
    public static void main(String[] args) throws Exception {
        byte[] data = Files.readAllBytes(Paths.get(args[0]));
        Class<?> parser = Class.forName("com.google.android.mms.pdu.PduParser");
        Object p = parser.getConstructor(byte[].class, boolean.class).newInstance(data, true);
        Object pdu = parser.getMethod("parse").invoke(p);
        if (pdu == null) { System.out.println("ANDROID'S PARSER REJECTS IT (parse() == null), " + data.length + " bytes"); return; }
        System.out.println("parsed as " + pdu.getClass().getSimpleName() + ", message type " + call(pdu, "getMessageType") + ", version " + call(pdu, "getMmsVersion"));
        try { System.out.println("transaction id " + s(call(pdu, "getTransactionId"))); } catch (Exception e) {}
        try { Object f = call(pdu, "getFrom"); System.out.println("from " + (f == null ? "null (insert-address)" : s(call(f, "getString")))); } catch (Exception e) { System.out.println("from: " + e); }
        try { Object[] to = (Object[]) call(pdu, "getTo"); if (to != null) for (Object t : to) System.out.println("to " + s(call(t, "getString"))); } catch (Exception e) { System.out.println("to: " + e); }
        try { System.out.println("content type " + s(call(pdu, "getContentType"))); } catch (Exception e) {}
        try { System.out.println("delivery report " + call(pdu, "getDeliveryReport") + ", read report " + call(pdu, "getReadReport")); } catch (Exception e) {}
        try { Object m = call(pdu, "getMessageId"); System.out.println("message id " + s(m)); } catch (Exception e) {}
        try { System.out.println("response status " + call(pdu, "getResponseStatus")); } catch (Exception e) {}
        try {
            Object body = call(pdu, "getBody");
            int n = (Integer) call(body, "getPartsNum");
            System.out.println(n + " parts");
            for (int i = 0; i < n; i++) {
                Object part = call(body, "getPart", i);
                byte[] d = (byte[]) call(part, "getData");
                System.out.println("  part " + i + ": type " + s(call(part, "getContentType")) + ", name " + s(call(part, "getName")) + ", location " + s(call(part, "getContentLocation"))
                    + ", id " + s(call(part, "getContentId")) + ", charset " + call(part, "getCharset") + ", " + (d == null ? 0 : d.length) + " bytes"
                    + (d != null && d.length > 4 ? String.format(", starts %02x %02x %02x %02x", d[0], d[1], d[2], d[3]) : ""));
            }
        } catch (Exception e) { System.out.println("body: " + e); }
    }
}

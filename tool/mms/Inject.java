import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Hands the phone an SMS PDU as if the radio had received it (ISms.injectSmsPduForSubscriber), as root on an emulator. */
public class Inject {
    public static void main(String[] a) throws Exception {
        byte[] pdu = Files.readAllBytes(Paths.get(a[0]));
        int sub = Integer.parseInt(a[1]);
        Object binder = Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "isms");
        Object isms = Class.forName("com.android.internal.telephony.ISms$Stub").getMethod("asInterface", Class.forName("android.os.IBinder")).invoke(null, binder);
        for (Method x : isms.getClass().getMethods()) {
            if (x.getName().equals("injectSmsPduForSubscriber")) {
                x.invoke(isms, sub, pdu, "3gpp", null);
                System.out.println("injected " + pdu.length + " bytes on subscription " + sub);
                return;
            }
        }
        System.out.println("no injectSmsPduForSubscriber on this phone");
    }
}

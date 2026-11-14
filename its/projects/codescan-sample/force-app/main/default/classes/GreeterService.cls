public class GreeterService {
    public String greeting;

    public String greet(String name) {
        System.debug('Hello ' + name);
        return 'Hello ' + name;
    }
}

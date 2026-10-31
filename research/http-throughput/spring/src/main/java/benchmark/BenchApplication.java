package benchmark;

import java.nio.charset.StandardCharsets;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class BenchApplication {
    public static void main(String[] args) {
        SpringApplication.run(BenchApplication.class, args);
    }

    @GetMapping("/health")
    public ResponseEntity<byte[]> health() {
        return reply("{\"status\":\"ok\"}".getBytes(StandardCharsets.UTF_8),
                "application/json; charset=utf-8");
    }

    @PostMapping("/echo")
    public ResponseEntity<byte[]> echo(@RequestBody byte[] body) {
        return reply(body, "text/plain; charset=utf-8");
    }

    private static ResponseEntity<byte[]> reply(byte[] body, String type) {
        return ResponseEntity.ok()
                .header("Connection", "close")
                .header("Content-Type", type)
                .contentLength(body.length)
                .body(body);
    }
}

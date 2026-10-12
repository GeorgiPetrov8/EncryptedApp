`server.test.js` needs three throwaway files in this folder:

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout tls.key -out tls.crt -days 1 -subj /CN=localhost
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out authkey.p8

They stand in for Apple's TLS certificate and your APNs key. Never commit a real key.

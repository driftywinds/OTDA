# Sign-in

Session cookie first (email + password, second factor, step-up for the
credential routes), API token second. The token is for scripts and for servers
where single sign-on has closed password sign-in. Credentials live in the
platform keystore (`flutter_secure_storage`), never in shared preferences.


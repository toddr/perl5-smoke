requires 'perl', '5.042000';

# core framework
requires 'Mojolicious',           '>= 9.34';
requires 'Mojo::SQLite',          '>= 3.009';
requires 'DBD::SQLite',           '>= 1.78';

# config
requires 'Mojolicious::Plugin::Config';

# misc
requires 'JSON::PP',              '>= 4.16';
requires 'Digest::MD5';
requires 'Date::Parse';

# request gzip + on-disk xz files
requires 'IO::Compress::Gzip';
requires 'IO::Uncompress::Gunzip';
requires 'IO::Compress::Xz';
requires 'IO::Uncompress::UnXz';

# YAML for OpenAPI spec
requires 'YAML::PP';

# CSP nonce generation + token generation
requires 'Crypt::URandom';

# Admin password hashing (Argon2id)
requires 'Crypt::Argon2';

# Carton -- bring Carton::Snapshot along so the snapshot file can be
# parsed at runtime if anything needs to (and cpm's snapshot resolver
# inside the base image has a stable provider).
requires 'Carton';

on 'develop' => sub {
    requires 'Test::More',        '>= 1.302';
    requires 'Test::Mojo';
    requires 'Test::Deep';
    requires 'Test::Warnings';
    requires 'Perl::Critic';
    requires 'Devel::Cover';
};

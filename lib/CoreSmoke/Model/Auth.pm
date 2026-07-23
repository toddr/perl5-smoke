package CoreSmoke::Model::Auth;
use v5.42;
use warnings;
use experimental qw(signatures);

use Crypt::Argon2   qw(argon2id_pass argon2id_verify);
use Crypt::URandom  qw(urandom);

my $ARGON2_T_COST = 3;
my $ARGON2_M_COST = '32M';
my $ARGON2_PARALLEL = 1;
my $ARGON2_TAG_SIZE = 32;
my $ARGON2_SALT_LEN = 16;

sub new ($class, %args) {
    my $sqlite = $args{sqlite} // die "sqlite required";
    my $pepper = $args{pepper} // die "pepper required";
    return bless { sqlite => $sqlite, pepper => $pepper }, $class;
}

# --- Admin users ---

sub create_user ($self, $username, $password) {
    die "username required"  unless defined $username && length $username;
    die "password required"  unless defined $password && length $password;

    my $hash = $self->_hash_password($password);
    my $db   = $self->{sqlite}->db;
    eval {
        $db->query(
            "INSERT INTO admin_user (username, password_hash) VALUES (?, ?)",
            $username, $hash,
        );
    };
    if (my $e = $@) {
        return { error => 'User already exists.' } if "$e" =~ /UNIQUE constraint failed/i;
        die $e;
    }
    return { ok => 1 };
}

my $DUMMY_HASH;

sub _dummy_hash {
    return $DUMMY_HASH //= argon2id_pass(
        '', urandom($ARGON2_SALT_LEN),
        $ARGON2_T_COST, $ARGON2_M_COST, $ARGON2_PARALLEL, $ARGON2_TAG_SIZE,
    );
}

sub verify_user ($self, $username, $password) {
    my $row = $self->{sqlite}->db->query(
        "SELECT password_hash FROM admin_user WHERE username = ?", $username,
    )->hash;
    my $hash = $row ? $row->{password_hash} : _dummy_hash();
    return unless argon2id_verify($hash, $password . $self->{pepper});
    return 1 if $row;
    return;
}

sub list_users ($self) {
    return $self->{sqlite}->db->query(
        "SELECT id, username, created_at, updated_at FROM admin_user ORDER BY id"
    )->hashes->to_array;
}

sub update_password ($self, $username, $new_password) {
    die "password required" unless defined $new_password && length $new_password;
    my $hash = $self->_hash_password($new_password);
    my $result = $self->{sqlite}->db->query(
        "UPDATE admin_user SET password_hash = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE username = ?",
        $hash, $username,
    );
    return $result->rows > 0 ? { ok => 1 } : { error => 'User not found.' };
}

sub delete_user ($self, $username) {
    my $count = $self->{sqlite}->db->query(
        "SELECT COUNT(*) AS cnt FROM admin_user"
    )->hash->{cnt};
    return { error => 'Cannot delete the last admin user.' } if $count <= 1;

    my $result = $self->{sqlite}->db->query(
        "DELETE FROM admin_user WHERE username = ?", $username,
    );
    return $result->rows > 0 ? { ok => 1 } : { error => 'User not found.' };
}

# --- API tokens ---

sub create_token ($self, %args) {
    my $note  = $args{note}  // '';
    my $email = $args{email} // '';

    my $token = unpack('H*', urandom(32));

    eval {
        $self->{sqlite}->db->query(
            "INSERT INTO api_token (token, note, email) VALUES (?, ?, ?)",
            $token, $note, $email,
        );
    };
    if (my $e = $@) {
        if ("$e" =~ /UNIQUE constraint failed/i) {
            $token = unpack('H*', urandom(32));
            $self->{sqlite}->db->query(
                "INSERT INTO api_token (token, note, email) VALUES (?, ?, ?)",
                $token, $note, $email,
            );
        }
        else { die $e }
    }

    my $row = $self->{sqlite}->db->query(
        "SELECT * FROM api_token WHERE token = ?", $token,
    )->hash;
    return $row;
}

sub list_tokens ($self) {
    return $self->{sqlite}->db->query(
        "SELECT id, token, note, email, created_at, cancelled_at, last_used_at, use_count FROM api_token ORDER BY cancelled_at IS NOT NULL, id DESC"
    )->hashes->to_array;
}

sub get_token ($self, $id) {
    return $self->{sqlite}->db->query(
        "SELECT * FROM api_token WHERE id = ?", $id,
    )->hash;
}

sub cancel_token ($self, $id) {
    my $result = $self->{sqlite}->db->query(
        "UPDATE api_token SET cancelled_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND cancelled_at IS NULL",
        $id,
    );
    return $result->rows > 0 ? { ok => 1 } : { error => 'Token not found or already cancelled.' };
}

sub validate_token ($self, $token_string) {
    return unless defined $token_string && length $token_string;
    return $self->{sqlite}->db->query(
        "SELECT * FROM api_token WHERE token = ? AND cancelled_at IS NULL",
        $token_string,
    )->hash;
}

sub record_token_use ($self, $token_id) {
    $self->{sqlite}->db->query(
        "UPDATE api_token SET use_count = use_count + 1, last_used_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
        $token_id,
    );
}

# --- Internal ---

sub _hash_password ($self, $password) {
    my $salt = urandom($ARGON2_SALT_LEN);
    return argon2id_pass(
        $password . $self->{pepper},
        $salt,
        $ARGON2_T_COST,
        $ARGON2_M_COST,
        $ARGON2_PARALLEL,
        $ARGON2_TAG_SIZE,
    );
}

1;

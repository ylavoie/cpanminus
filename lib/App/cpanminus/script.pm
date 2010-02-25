package App::cpanminus::script;
use strict;
use Config;
use Cwd ();
use File::Basename ();
use File::Spec ();
use File::Copy ();
use Getopt::Long ();

use constant WIN32 => $^O eq 'MSWin32';
use constant PLUGIN_API_VERSION => 0.1;

our $VERSION = "0.99_04";
$VERSION = eval $VERSION;

my $quote = $^O eq 'MSWin32' ? q/"/ : q/'/;

sub new {
    my $class = shift;

    bless {
        home => File::Spec->catfile($ENV{HOME}, ".cpanm"),
        cmd  => 'install',
        seen => {},
        notest => undef,
        installdeps => undef,
        force => undef,
        sudo => undef,
        make  => undef,
        verbose => undef,
        interactive => undef,
        log => undef,
        mirrors => [],
        perl => $^X,
        argv => undef,
        hooks => {},
        plugins => [],
        configure_timeout => 60,
        build_timeout => 60 * 10,
        test_timeout  => 60 * 10,
        @_,
    }, $class;
}

sub env {
    my($self, $key) = @_;
    $ENV{"PERL_CPANM_" . $key} || $ENV{"CPANMINUS_" . $key};
}

sub parse_options {
    my $self = shift;
    local @ARGV = @_;

    Getopt::Long::Configure("bundling");
    Getopt::Long::GetOptions(
        'f|force'  => \$self->{force},
        'n|notest' => \$self->{notest},
        'S|sudo'   => \$self->{sudo},
        'v|verbose' => sub { $self->{verbose} = $self->{interactive} = 1 },
        'q|quiet'   => sub {},
        'h|help'    => sub { $self->{action} = 'help' },
        'V|version' => sub { $self->{action} = 'version' },
        'perl'      => \$self->{perl},
        'recent'    => sub { $self->{action} = 'show_recent' },
        'list-plugins' => sub { $self->{action} = 'list_plugins' },
        'installdeps' => \$self->{installdeps},
        'interactive' => \$self->{interactive},
        'i|install' => sub { $self->{cmd} = 'install' },
        'look'      => sub { $self->{cmd} = 'look' },
        'info'      => sub { $self->{cmd} = 'info' },
        'self-upgrade' => sub { $self->{cmd} = 'install'; $self->{argv} = [ 'App::cpanminus' ] },
        'disable-plugins' => \$self->{disable_plugins},
    );

    $self->{argv} ||= \@ARGV;
}

sub init {
    my $self = shift;

    $self->setup_home;
    $self->load_plugins;
    $self->sanity_check;

    $self->{make} = $self->which($Config{make});
    $self->init_tools;
}

sub doit {
    my $self = shift;

    $self->init;
    $self->configure_mirrors;

    if (my $action = $self->{action}) {
        $self->$action() and return;
    }

    $self->help(1) unless @{$self->{argv}};

    for my $module (@{$self->{argv}}) {
        $self->install_module($module);
    }

    $self->run_hooks(finalize => {});
}

sub setup_home {
    my $self = shift;

    $self->{home} = $self->env('HOME') if $self->env('HOME');
    mkdir $self->{home}, 0777 unless -e $self->{home};

    for my $dir (qw( plugins work )) {
        my $sub = File::Spec->catfile($self->{home}, $dir);
        unless (-e $sub) {
            mkdir $sub, 0777 or die "$dir: $!";
        }
    }

    $self->{base} = File::Spec->catfile($self->{home}, "work", time . ".$$");
    mkdir $self->{base}, 0777 or die "$self->{base}: $!";

    my $link = File::Spec->catfile($self->{home}, 'latest-build');
    eval { unlink $link; symlink $self->{base}, $link };

    $self->{log} = File::Spec->catfile($self->{home}, "build.log");

    {
        my $log = $self->{log}; my $base = $self->{base};
        $self->{at_exit} = sub { File::Copy::copy($log, File::Spec->catfile($base, 'build.log')) };
    }

    open my $out, ">$self->{log}" or die "$self->{log}: $!";
    print $out "cpanm (App::cpanminus) $VERSION on perl $] built for $Config{archname}\n";
    print $out "Work directory is $self->{base}\n";

    $self->{plugin_dir} = File::Spec->catfile($self->{home}, "plugins");
}

sub register_core_hooks {
    my $self = shift;

    $self->hook('core', search_module => sub {
        my $args = shift;
        push @{$args->{uris}}, sub {
            $self->chat("Searching $args->{module} on search.cpan.org ...\n");
            my $uri  = "http://search.cpan.org/perldoc?$args->{module}";
            my $html = $self->get($uri);
            $html =~ m!<a href="/CPAN/authors/id/(.*?\.(?:tar\.gz|tgz|tar\.bz2|zip))">!
                and return $self->cpan_uri($1);
            $self->diag("! Finding $args->{module} on search.cpan.org failed.\n");
            return;
        };
    });

    $self->hook('core', show_recent => sub {
        my $args = shift;

        $self->chat("Fetching recent feed from search.cpan.org ...\n");
        my $feed = $self->get("http://search.cpan.org/uploads.rdf");

        my @dists;
        while ($feed =~ m!<link>http://search\.cpan\.org/~([a-z_\-0-9]+)/(.*?)/</link>!g) {
            my($pause_id, $dist) = (uc $1, $2);
            # FIXME Yes, it doesn't always have to be 'tar.gz'
            push @dists, substr($pause_id, 0, 1) . "/" . substr($pause_id, 0, 2) . "/" . $pause_id . "/$dist.tar.gz";
            last if @dists >= 50;
        }

        return \@dists;
    });
}

sub load_plugins {
    my $self = shift;

    $self->_load_plugins;
    $self->register_core_hooks;

    for my $hook (keys %{$self->{hooks}}) {
        $self->{hooks}->{$hook} = [ sort { $a->[0] <=> $b->[0] } @{$self->{hooks}->{$hook}} ];
    }

    $self->run_hooks(init => {});
}

sub _load_plugins {
    my $self = shift;
    return if $self->{disable_plugins};
    return unless $self->{plugin_dir} && -e $self->{plugin_dir};

    opendir my $dh, $self->{plugin_dir} or return;
    my @plugins;
    while (my $e = readdir $dh) {
        my $f = File::Spec->catfile($self->{plugin_dir}, $e);
        next unless -f $f && $e =~ /^[A-Za-z0-9_]+$/ && $e ne 'README';
        push @plugins, [ $f, $e ];
    }

    for my $plugin (sort { $a->[1] <=> $b->[1] } @plugins) {
        $self->load_plugin(@$plugin);
    }
}

sub load_plugin {
    my($self, $file, $name) = @_;

    # TODO remove this once plugin API is official
    unless ($self->env('DEV')) {
        $self->chat("! Found plugin $file but PERL_CPANM_DEV is not set. Skipping.\n");
        return;
    }

    $self->chat("Loading plugin $file\n");

    my $plugin = { name => $name, file => $file };
    my @attr   = qw( name description author version synopsis );
    my $dsl    = join "\n", map "sub $_ { \$plugin->{$_} = shift }", @attr;

    (my $package = $file) =~ s/[^a-zA-Z0-9_]/_/g;
    my $code = do { open my $io, "<$file"; local $/; <$io> };

    my $api_version = PLUGIN_API_VERSION;

    my @hooks;
    eval "package App::cpanplus::plugin::$package;\n".
        "use strict;\n$dsl\n" .
        'sub api_version { die "API_COMPAT: $_[0]" if $_[0] < $api_version }' . "\n" .
        "sub hook { push \@hooks, [\@_] };\n$code";

    if ($@ =~ /API_COMPAT: (\S+)/) {
        $self->diag("! $plugin->{name} plugin API version is outdated ($1 < $api_version) and needs an update.\n");
        return;
    } elsif ($@) {
        $self->diag("! Loading $name plugin failed. See $self->{log} for details.\n");
        $self->chat($@);
        return;
    }

    for my $hook (@hooks) {
        $self->hook($plugin->{name}, @$hook);
    }

    push @{$self->{plugins}}, $plugin;
}

sub hook {
    my $cb = pop;
    my($self, $name, $hook, $order) = @_;
    $order = 50 unless defined $order;
    push @{$self->{hooks}->{$hook}}, [ $order, $cb, $name ];
}

sub run_hook {
    my($self, $hook, $args) = @_;
    $self->run_hooks($hook, $args, 1);
}

sub run_hooks {
    my($self, $hook, $args, $first) = @_;

    my $res;
    for my $plugin (@{$self->{hooks}->{$hook} || []}) {
        $res = eval { $plugin->[1]->({ %$args, app => $self }) };
        $self->chat("Running hook '$plugin->[2]' error: $@") if $@;
        last if $res && $first;
    }

    return $res;
}

sub version {
    print "cpanm (App::cpanminus) version $VERSION\n";
    return 1;
}

sub help {
    my $self = shift;
    my $how  = $_[0] ? sub { die @_ } : sub { print @_ };
    $how->(<<USAGE);
Usage: cpanm [options] Module [...]

Options:
  -v,--verbose       Turns on chatty output
  --interactive      Turns on interactive configure (required for Task:: modules)
  -f,--force         force install
  -n,--notest        Do not run unit tests
  -S,--sudo          sudo to run install commands
  --installdeps      Only install dependencies
  --disable-plugins  Disable plugin loading

Commands:
  --self-upgrade     upgrades itself
  --look             Download the tarball and open the directory with your shell
  --info             Displays distribution info on CPAN
  --recent           Show recently updated modules

Examples:

  # install CGI
  cpanm CGI

  # specify the version
  cpanm MIYAGAWA/Plack-0.99_05.tar.gz

  # install from an URL
  cpanm http://backpan.perl.org/authors/id/L/LD/LDS/CGI.pm-3.20.tar.gz

  # install Task:: modlues (You need --interactive or -v to answer questions)
  cpanm --interactive Task::Kensho

  # install from local directory, just like `cpan .`
  cpanm .

  # install all the dependencies for the current directory
  cpanm --installdeps .

  # install from a local file
  cpanm ~/dists/MyCompany-Enterprise-1.00.tar.gz

USAGE

    return 1;
}

sub sanity_check {
    my $self = shift;
    unless (   ($ENV{PERL_MM_OPT} and ($ENV{MODULEBUILDRC} or $ENV{PERL_MB_OPT}))
            or -w $Config{installsitelib} or $self->{sudo}) {
        die "Can't write to $Config{installsitelib}: Run me as root or with --sudo option.\n";
    }
}

sub diag {
    my $self = shift;
    print STDERR @_;
    $self->log(@_);
}

sub chat {
    my $self = shift;
    print STDERR @_ if $self->{verbose};
    $self->log(@_);
}

sub log {
    my $self = shift;
    open my $out, ">>$self->{log}";
    print $out @_;
}

sub run {
    my($self, $cmd) = @_;
    unless ($self->{verbose}) {
        $cmd .= " >> " . $self->shell_quote($self->{log}) . " 2>&1";
    }
    !system $cmd;
}

sub run_exec {
    my($self, $cmd) = @_;
    unless ($self->{verbose}) {
        $cmd .= " >> " . $self->shell_quote($self->{log}) . " 2>&1";
    }
    exec $cmd;
    return;
}

sub run_timeout {
    my($self, $cmd, $timeout) = @_;
    return $self->run($cmd) if WIN32 || $self->{verbose};

    my $pid = fork;
    if ($pid) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $timeout;
            waitpid $pid, 0;
            alarm 0;
        };
        if ($@ && $@ eq "alarm\n") {
            $self->diag("Timed out (> ${timeout}s). Use --verbose to retry. ");
            local $SIG{TERM} = 'IGNORE';
            kill TERM => 0;
            waitpid $pid, 0;
            return;
        }
        return !$?;
    } elsif ($pid == 0) {
        $self->run_exec($cmd);
    } else {
        $self->chat("! fork failed: falling back to system()\n");
        $self->run($cmd);
    }
}

sub configure {
    my($self, $cmd) = @_;

    # trick AutoInstall
    local $ENV{PERL5_CPAN_IS_RUNNING} = $ENV{PERL5_CPANPLUS_IS_RUNNING} = 1;

    my $use_default = !$self->{interactive};
    local $ENV{PERL_MM_USE_DEFAULT} = $use_default;
    local $ENV{AUTOMATED_TESTING}   = $use_default;

    local $self->{verbose} = $self->{interactive};
    $self->run_timeout($cmd, $self->{configure_timeout});
}

sub build {
    my($self, $cmd) = @_;
    $self->run_timeout($cmd, $self->{build_timeout});
}

sub test {
    my($self, $cmd) = @_;
    return 1 if $self->{notest};
    return $self->run_timeout($cmd,  $self->{test_timeout}) || $self->{force};
}

sub install {
    my($self, $cmd) = @_;
    $cmd = "sudo $cmd" if $self->{sudo};
    $self->run($cmd);
}

sub chdir {
    my $self = shift;
    chdir(File::Spec->canonpath($_[0])) or die "$_[0]: $!";
}

sub configure_mirrors {
    my $self = shift;

    my @mirrors;
    $self->run_hook(configure_mirrors => { mirrors => \@mirrors });

    @mirrors = ('http://search.cpan.org/CPAN') unless @mirrors;
    $self->{mirrors} = \@mirrors;
}

sub show_recent {
    my $self = shift;

    my $dists = $self->run_hook(show_recent => {});
    for my $dist (@$dists) {
        print $dist, "\n";
    }

    return 1;
}

sub list_plugins {
    my $self = shift;

    for my $plugin (@{$self->{plugins}}) {
        print "$plugin->{name} - $plugin->{description}\n";
    }

    return 1;
}

sub self_upgrade {
    my $self = shift;
    $self->{argv} = [ 'App::cpanminus' ];
    return; # continue
}

sub install_module {
    my($self, $module, $is_dep) = @_;

    if ($self->{seen}{$module}++) {
        $self->diag("Already tried $module. Skipping.\n");
        return;
    }

    my $dir = $self->fetch_module($module);

    return if $self->{cmd} eq 'info';

    unless ($dir) {
        $self->diag("! Couldn't find module or a distribution $module\n");
        return;
    }

    if ($self->{seen}{$dir}++) {
        $self->diag("Already built the distribution $dir. Skipping.\n");
        return;
    }

    $self->chat("Entering $dir\n");
    $self->chdir($self->{base});
    $self->chdir($dir);

    if ($self->{cmd} eq 'look') {
        my $shell = $ENV{SHELL};
        $shell  ||= $ENV{COMSPEC} if WIN32;
        if ($shell) {
            $self->diag("Entering $dir with $shell\n");
            system $shell;
        } else {
            $self->diag("! You don't seem to have a SHELL :/\n");
        }
    } else {
        $self->build_stuff($module, $dir, $is_dep)
    }
}

sub generator_cb {
    my($self, $ref) = @_;

    $ref = [ $ref ] unless ref $ref eq 'ARRAY';

    my @stack;
    return sub {
        if (@stack) {
            return shift @stack;
        }

        return -1 unless @$ref;
        my $curr = (shift @$ref)->();
        if (ref $curr eq 'ARRAY') {
            @stack = @$curr;
            return shift @stack;
        } else {
            return $curr;
        }
    };
}

sub fetch_module {
    my($self, $module) = @_;

    my($uris, $local_dir) = $self->locate_dist($module);

    return $local_dir if $local_dir;
    return unless $uris;

    my $iter = $self->generator_cb($uris);

    while (1) {
        my $uri = $iter->();
        last if $uri == -1;
        next unless $uri;

        # Yikes this is dirty
        if ($self->{cmd} eq 'info') {
            $uri =~ s!.*authors/id/!!;
            print $uri, "\n";
            return;
        }

        if ($uri =~ m{/perl-5}){
            $self->diag("skip $uri\n");
            next;
        }

        $self->chdir($self->{base});
        $self->diag("Fetching $uri ... ");

        my $name = File::Basename::basename $uri;

        my $cancelled;
        my $fetch = sub {
            eval {
                local $SIG{INT} = sub { $cancelled = 1; die "SIGINT\n" };
                $self->mirror($uri, $name);
                return $name if -e $name;
                return;
            };
        };

        my($try, $file);
        while ($try++ < 3) {
            $file = $fetch->();
            last if $cancelled or $file;
            $self->diag("FAIL\nDownload $uri failed. Retrying ... ");
        }

        if ($cancelled) {
            $self->diag("\n! Download cancelled.\n");
            return;
        }

        unless ($file) {
            $self->diag("FAIL\n! Failed to download $uri\n");
            next;
        }

        $self->diag("OK\n");
        $self->chat("Unpacking $file\n");

        my $dir = $file =~ /\.zip/i ? $self->unzip($file) : $self->untar($file);
        unless ($dir) {
            $self->diag("! Failed to unpack $name: no directory\n");
            next;
        }

        return $dir;
    }
}

sub locate_dist {
    my($self, $module) = @_;

    if (my $located = $self->run_hook(locate_dist => { module => $module })) {
        return ref $located eq 'ARRAY' ? @$located :
               ref $located eq 'CODE'  ? $located  : sub { $located };
    }

    # URL
    return sub { $module } if $module =~ /^(ftp|https?|file):/;

    # Directory
    return undef, Cwd::abs_path($module) if -e $module && -d _;

    # File
    return sub { "file://" . Cwd::abs_path($module) } if -f $module;

    # cpan URI
    $module =~ s!^cpan:///distfile/!!;

    # PAUSEID/foo
    $module =~ s!^([A-Z]{3,})/!substr($1, 0, 1)."/".substr($1, 0, 2) ."/" . $1 . "/"!e;

    # CPAN tarball
    return sub { $self->cpan_uri($module) } if $module =~ m!^[A-Z]/[A-Z]{2}/!;

    # Module name -- search.cpan.org
    return $self->search_module($module);
}

sub cpan_uri {
    my($self, $dist) = @_;

    my @mirrors = @{$self->{mirrors}};
    my @urls    = map "$_/authors/id/$dist", @mirrors;

    return wantarray ? @urls : $urls[int(rand($#urls))];
}

sub search_module {
    my($self, $module) = @_;

    my @cbs;
    $self->run_hooks(search_module => { module => $module, uris => \@cbs });

    return \@cbs;
}

sub check_module {
    my($self, $mod, $ver) = @_;

    $ver = '' if $ver == 0;
    my $test = `$self->{perl} -e ${quote}eval q{use $mod $ver (); print q{OK:}, $mod\::->VERSION};print \$\@ if \$\@${quote}`;
    if ($test =~ s/^\s*OK://) {
        return 1, $test;
    } elsif ($test =~ /^Can't locate|required--this is only version (\S+)/) {
        return 0, $1;
    } else {
        return 0, undef, $test;
    }
}

sub install_deps {
    my($self, $dir, %deps) = @_;

    my @install;
    while (my($mod, $ver) = each %deps) {
        next if $mod eq 'perl' or $mod eq 'Config';
        $self->chat("Checking if you have $mod $ver ... ");
        my($ok, $local, $err) = $self->check_module($mod, $ver);

        if ($err) {
            $self->chat("Unknown ($err)\n");
            next;
        }

        if ($ok)       { $self->chat("Yes ($local)\n") }
        elsif ($local) { $self->chat("No ($local < $ver)\n") }
        else           { $self->chat("No\n") }

        push @install, $mod unless $ok;
    }

    if (@install) {
        $self->diag("==> Found dependencies: ", join(", ", @install), "\n");
    }

    for my $mod (@install) {
        $self->install_module($mod, 1);
    }

    $self->chdir($self->{base});
    $self->chdir($dir);
}

sub build_stuff {
    my($self, $module, $dir, $is_dep) = @_;

    my $fail;
    $self->run_hooks(verify_dist => { module => $module, dir => $dir, fail => \$fail });

    if ($fail && !$self->{force}) {
        $self->diag("! Verifying the module $module failed. Skipping. (use --force to install)\n");
        return;
    }

    my $meta;
    if (-e 'META.yml') {
        $self->chat("Checking configure dependencies from META.yml ...\n");
        $meta = $self->parse_meta('META.yml');
        my %deps = %{$meta->{configure_requires} || {}};

        $self->install_deps($dir, %deps);
    }

    my $target = $meta->{name} ? "$meta->{name}-$meta->{version}" : $dir;
    $self->diag("Configuring $target ... ");

    my($use_module_build, $configured, $configured_ok);
    if (-e 'Makefile.PL') {
        local $ENV{X_MYMETA} = 'YAML';

        # NOTE: according to Devel::CheckLib, most XS module' exit
        # with 0 even if header files are missing, to avoid receiving
        # tons of FAIL reports in such cases. So exit code can't be
        # trusted if it went well (See Devel::CheckLib comments for
        # details)
        if ($self->configure("$self->{perl} Makefile.PL")) {
            $configured_ok = -e 'Makefile';
        }
        $configured++;
    }

    if ((!$self->{make} or !$configured_ok) and -e 'Build.PL') {
        if ($self->configure("$self->{perl} Build.PL")) {
            $configured_ok = -e 'Build' && -f _;
        }
        $use_module_build++;
        $configured++;
    }

    my %deps;
    if (-e 'MYMETA.yml') {
        $self->chat("Checking dependencies from MYMETA.yml ...\n");
        $meta = $self->parse_meta('MYMETA.yml');
        %deps = (%{$meta->{requires} || {}});
        unless ($self->{notest}) {
            %deps = (%deps, %{$meta->{build_requires} || {}}, %{$meta->{test_requires} || {}});
        }
    }

    if (-e 'Makefile') {
        $self->chat("Finding PREREQ from Makefile ...\n");
        open my $mf, "Makefile";
        while (<$mf>) {
            if (/^\#\s+PREREQ_PM => ({.*?})/) {
                no strict; # WTF bareword keys
                my $prereq = eval "+$1";
                %deps = (%deps, %$prereq) if $prereq;
                last;
            }
        }
    }

    $self->diag($configured_ok ? "OK\n" : "N/A\n");

    $self->run_hooks(find_deps => { deps => \%deps, module => $module, meta => $meta });

    $self->install_deps($dir, %deps);

    if ($self->{installdeps} && !$is_dep) {
        $self->diag("<== Installed dependencies for $module. Finishing.\n");
        return 1;
    }

    my $installed;
    if ($use_module_build && -e 'Build' && -f _) {
        $self->diag("Building ", ($self->{notest} ? "" : "and testing "), "$target for $module ... ");
        $self->build("$self->{perl} ./Build") &&
        $self->test("$self->{perl} ./Build test") &&
        $self->install("$self->{perl} ./Build install") &&
        $installed++;
    } elsif ($self->{make} && -e 'Makefile') {
        $self->diag("Building ", ($self->{notest} ? "" : "and testing "), "$target for $module ... ");
        $self->build("$self->{make}") &&
        $self->test("$self->{make} test") &&
        $self->install("$self->{make} install") &&
        $installed++;
    } else {
        my $why;
        if ($configured)      { $why = "Configure failed on $dir." }
        elsif ($self->{make}) { $why = "The distribution doesn't have a proper Makefile.PL/Build.PL" }
        else                  { $why = "Can't configure the distribution. You probably need to have 'make'." }

        $self->diag("! $why See $self->{log} for details.\n");
        $self->run_hooks(configure_failure => { module => $module, build_dir => $dir, meta => $meta });
        return;
    }

    if ($installed) {
        $self->diag("OK\n$module installed successfully.\n");
        $self->run_hooks(install_success => { module => $module, build_dir => $dir, meta => $meta });
        return 1;
    } else {
        $self->diag("FAIL\n! Installing $module failed. See $self->{log} for details.\n");
        $self->run_hooks(build_failure => { module => $module, build_dir => $dir, meta => $meta });
        return;
    }
}

sub DESTROY {
    my $self = shift;
    $self->{at_exit}->($self) if $self->{at_exit};
}

# Utils

sub shell_quote {
    my($self, $stuff) = @_;
    $quote . $stuff . $quote;
}

sub which {
    my($self, $name) = @_;
    my $exe_ext = $Config{_exe};
    for my $dir (File::Spec->path) {
        my $fullpath = File::Spec->catfile($dir, $name);
        if (-x $fullpath || -x ($fullpath .= $exe_ext)) {
            if ($fullpath =~ /\s/ && $fullpath !~ /^$quote/) {
                $fullpath = $self->shell_quote($fullpath);
            }
            return $fullpath;
        }
    }
    return;
}

sub get      { shift->{_backends}{get}->(@_) };
sub mirror   { shift->{_backends}{mirror}->(@_) };
sub redirect { shift->{_backends}{redirect}->(@_) };
sub untar    { shift->{_backends}{untar}->(@_) };
sub unzip    { shift->{_backends}{unzip}->(@_) };

sub file_mirror {
    my($self, $uri, $path) = @_;
    File::Copy::copy($uri, $path);
}

sub init_tools {
    my $self = shift;

    # use PERL_CPANM_NO_LWP=1 if they have a broken LWP, to upgrade LWP
    if (!$self->env('NO_LWP') && eval { require LWP::Simple }) {
        require LWP::UserAgent; # needed for LWP < 5.828
        $self->{_backends}{get} = sub {
            my $self = shift;
            my $ua = LWP::UserAgent->new(parse_head => 0, env_proxy => 1);
            $ua->request(HTTP::Request->new(GET => $_[0]))->decoded_content;
        };
        $self->{_backends}{mirror} = sub {
            my $self = shift;
            LWP::Simple::mirror(@_);
        };
        $self->{_backends}{redirect} = sub {
            my $self = shift;
            my $ua   = LWP::UserAgent->new(parse_head => 0, max_redirect => 1, env_proxy => 1);
            my $res  = $ua->simple_request(HTTP::Request->new(GET => $_[0]));
            return $res->header('Location') if $res->is_redirect;
            return;
        };
    } elsif (my $wget = $self->which('wget')) {
        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            my $q = $self->{verbose} ? '' : '-q';
            open my $fh, "$wget $uri $q -O - |" or die "wget $uri: $!";
            local $/;
            <$fh>;
        };
        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-q';
            system "$wget $uri $q -O $path";
        };
        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            my $out = `$wget --max-redirect=0 $uri 2>&1`;
            if ($out =~ /^Location: (\S+)/m) {
                return $1;
            }
            return;
        };
    }
    # TODO curl

    if (my $tar = $self->which('tar')){
        $self->{_backends}{untar} = sub {
            my($self, $tarfile) = @_;

            my $xf = "xf" . ($self->{verbose} ? 'v' : '');
            my $ar = $tarfile =~ /bz2$/ ? 'j' : 'z';

            my($root, @others) = `$tar tf$ar $tarfile`
                or return undef;

            chomp $root;
            $root =~ s{^(.+)/[^/]*$}{$1};

            system "$tar $xf$ar $tarfile";
            return $root if -d $root;

            $self->diag("! Bad archive: $tarfile\n");
            return undef;
        }
    } elsif (eval { require Archive::Tar }) { # uses too much memory!
        $self->{_backends}{untar} = sub {
            my $self = shift;
            my $t = Archive::Tar->new($_[0]);
            my $root = ($t->list_files)[0];
            $t->extract;
            return -d $root ? $root : undef;
        };
    }
    if (my $unzip = $self->which('unzip')) {
        $self->{_backends}{unzip} = sub {
            my($self, $zipfile) = @_;

            my $opt = $self->{verbose} ? '' : '-q';
            my(undef, $root, @others) = `$unzip -t $zipfile`
                or return undef;

            chomp $root;
            $root =~ s{^\s+testing:\s+(.+?)/\s+OK$}{$1};

            system "$unzip $opt $zipfile";
            return $root if -d $root;

            $self->diag("! Bad archive: [$root] $zipfile\n");
            return undef;
        }
    } elsif (eval { require Archive::Zip }) {
        $self->{_backends}{unzip} = sub {
            my($self, $file) = @_;
            my $zip = Archive::Zip->new();
            my $status;
            $status = $zip->read($file);
            $self->diag("Read of file[$file] failed\n")
                if $status != Archive::Zip::AZ_OK();
            my @members = $zip->members();
            my $root;
            for my $member ( @members ) {
                my $af = $member->fileName();
                next if ($af =~ m!^(/|\.\./)!);
                $root = $af unless $root;
                $status = $member->extractToFileNamed( $af );
                $self->diag("Extracting of file[$af] from zipfile[$file failed\n") if $status != Archive::Zip::AZ_OK();
            }
            return -d $root ? $root : undef;
        };
    }
}

sub parse_meta {
    my($self, $file) = @_;
    return eval { (Parse::CPAN::Meta::LoadFile($file))[0] } || {};
}

1;

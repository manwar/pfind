package App::Pfind;

use 5.022;
use strict;
use warnings;

use Getopt::Long qw(GetOptionsFromArray :config auto_abbrev no_ignore_case
                    permute auto_version);
use Pod::Usage;
use File::Find;
use Safe;

our $VERSION = '1.01';

{
  # A simple way to make a scalar be read-only.
  package App::Pfind::ReadOnlyVar;
  sub TIESCALAR {
    my ($class, $value) = @_;
    return bless \$value, $class;
  }
  sub FETCH {
    my ($self) = @_;
    return $$self;
  }
  # Does nothing. We could warn_or_die, but it does not play well with the fact
  # that we are inside the safe.
  sub STORE {}
  # Secret hidden methods for our usage only. These methods can't be used
  # through the tie-ed variable, but only through the object returned by the
  # call to tie.
  sub set {
    my ($self, $value) = @_;
    $$self = $value;
  }
}

# These two variables are shared with the user code. They have this name as a
# localized copy is passed to the code.
our ($internal_pfind_dir, $internal_pfind_name);
my $dir_setter = tie $internal_pfind_dir, 'App::Pfind::ReadOnlyVar';
my $name_setter = tie $internal_pfind_name, 'App::Pfind::ReadOnlyVar';

# A Safe object, created in reset_options.
my $safe;

# This hash contains options that are global for the whole program.
my %options;

sub prune {
  die "The prune command cannot be used when --depth-first is set.\n" if $options{depth_first};
  $File::Find::prune = 1;
}

sub reset_options {
  $safe = Safe->new();
  $safe->deny_only(':subprocess', ':ownprocess', ':others', ':dangerous');
  $safe->reval('use File::Spec::Functions qw(:ALL);');
  $safe->share('$internal_pfind_dir', '$internal_pfind_name', 'prune');

  # Whether to process the content of a directory before the directory itself.
  $options{depth_first} = 0;
  # Whether to follow the symlinks.
  $options{follow} = 0;
  # Whether to follow the symlinks using a fast method that may process some files twice.
  $options{follow_fast} = 0;
  # Block of code to execute before the main loop
  $options{begin} = [];
  # Block of code to execute after the main loop
  $options{end} = [];
  # Block of code to execute for each file and directory encountered
  $options{exec} = [];
  # Whether to chdir in the crawled directories
  $options{chdir} = 1;
  # Whether to catch errors returned in $! in user code
  $options{catch_errors} = 1;  # non-modifiable for now.
  # Add this string after each print statement
  $options{print} = "\n";
}

sub all_options {(
  'help|h' => sub { pod2usage(-exitval => 0, -verbose => 2) },
  'depth-first|depth|d!' => \$options{depth_first},
  'follow|f!' => \$options{follow},
  'follow-fast|ff!' => \$options{follow_fast},
  'chdir!' => \$options{chdir},
  'print|p=s' => \$options{print},
  'begin|BEGIN|B=s@' => $options{begin},
  'end|END|E=s@' => $options{end},
  'exec|e=s@' => $options{exec}
)}

sub eval_code {
  my ($code, $flag) = @_;
  my $r = $safe->reval($code);
  if ($@) {
    die "Failure in the code given to --${flag}: ${@}\n";
  }
  return $r;
}

sub Run {
  my ($argv) = @_;
  
  reset_options();
  # After the GetOptions call this will contain the input directories.
  my @inputs = @$argv;
  GetOptionsFromArray(\@inputs, all_options())
    or pod2usage(-exitval => 2, -verbose => 0);
    
  if (not @{$options{exec}}) {
    $options{exec} = ['print'];
  }
    
  if ($options{follow} && $options{follow_fast}) {
    die "The --follow and --follow-fast options cannot be used together.\n";
  }
  
  $\ = $options{print};
  
  for my $c (@{$options{begin}}) {
    eval_code($c, 'BEGIN');
  }
  
  # We're building a sub that will execute each given piece of code in a block.
  # That way we can evaluate this code in the safe once and get the sub
  # reference (so that it does not need to be recompiled for each file). In
  # addition, control flow keywords (mainly next, redo and return) can be used
  # in each block.
  my $block_start = '{ my $tmp_pfind_default = $_; '
                    .'local $_ = $tmp_pfind_default;'
                    .'local $dir = $internal_pfind_dir;'
                    .'local $name = $internal_pfind_name;';
  my $block_end = $options{catch_errors} ? '} die "$!\n" if $!;' : '} ';
  my $all_exec_code = "sub { ${block_start}".join("${block_end} \n ${block_start}", @{$options{exec}})."${block_end} }";
  my $wrapped_code = eval_code($all_exec_code, 'exec');
  
  find({
    bydepth => $options{depth_first},
    follow => $options{follow},
    follow_fast => $options{follow_fast},
    no_chdir => !$options{chdir},
    wanted => sub {
      # Instead of using our local variables, we could share the real one here:
      # $safe->share_from('File::Find', ['$dir', '$name']);
      # They have to be shared inside the sub as they are 'localized' each time.
      # That approach would be slower by a small factor though.
      $dir_setter->set($File::Find::dir);
      $name_setter->set($File::Find::name);
      $wrapped_code->();
      die "Failure in the code given to --exec: $!\n" if $!;
    },
  }, @inputs);

  for my $c (@{$options{end}}) {
    eval_code($c, 'BEGIN');
  }
}

1;

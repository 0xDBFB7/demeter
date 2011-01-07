package Demeter::ScatteringPath::Histogram::DL_POLY;

=for Copyright
 .
 Copyright (c) 2006-2011 Bruce Ravel (bravel AT bnl DOT gov).
 All rights reserved.
 .
 This file is free software; you can redistribute it and/or
 modify it under the same terms as Perl itself. See The Perl
 Artistic License.
 .
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut

use strict;
use warnings;

use Moose;
use MooseX::Aliases;
#use MooseX::StrictConstructor;
extends 'Demeter';
use Demeter::StrTypes qw( Empty );
use Demeter::NumTypes qw( Natural PosInt NonNeg );

use POSIX qw(acos);
use Readonly;
Readonly my $PI => 4*atan2(1,1);

with 'Demeter::Data::Arrays';
with 'Demeter::UI::Screen::Pause' if ($Demeter::mode->ui eq 'screen');
if ($Demeter::mode->ui eq 'screen') {
  with 'Demeter::UI::Screen::Pause';
  with 'Demeter::UI::Screen::Progress';
};

use List::Util qw{sum};

has '+plottable'      => (default => 1);

## HISTORY file attributes
has 'nsteps'    => (is => 'rw', isa => NonNeg, default => 0);
has 'file'      => (is => 'rw', isa => 'Str', default => q{},
		    trigger => sub{ my($self, $new) = @_;
				    if ($new and (-e $new)) {
				      $self->_cluster;
				      $self->rdf if $self->ss;
				      $self->nearly_collinear if $self->ncl;
				    };
				  });
has 'clusters'    => (is => 'rw', isa => 'ArrayRef', default => sub{[]});

## SS histogram attributes
has 'update_bins' => (is            => 'rw',
		      isa           => 'Bool',
		      default       => 1);
has 'rmin'        => (is	    => 'rw',
		      isa	    => 'Num',
		      default	    => 0.0,
		      trigger	    => sub{ my($self, $new) = @_; $self->update_bins(1) if $new},
		      documentation => "The lower bound of the SS histogram to be extracted from the cluster");
has 'rmax'        => (is	    => 'rw',
		      isa	    => 'Num',
		      default	    => 5.6,
		      trigger	    => sub{ my($self, $new) = @_; $self->update_bins(1) if $new},
		      documentation => "The upper bound of the SS histogram to be extracted from the cluster");
has 'bin'         => (is            => 'rw',
		      isa           => 'Num',
		      default       => 0.005,);
has 'ssrdf'       => (is	    => 'rw',
		      isa	    => 'ArrayRef',
		      default	    => sub{[]},
		      documentation => "unbinned distribution extracted from the cluster");
has 'npairs'      => (is            => 'rw',
		      isa           => NonNeg,
		      default       => 0);
has 'positions'   => (is            => 'rw',
		      isa           => 'ArrayRef',
		      default       => sub{[]},
		      documentation => "array of bin positions of the extracted histogram");
has 'populations' => (is	    => 'rw',
		      isa	    => 'ArrayRef',
		      default	    => sub{[]},
		      documentation => "array of bin populations of the extracted histogram");

## nearly collinear DS and TS historgram attributes
has 'skip'      => (is => 'rw', isa => 'Int', default => 50,);
has 'nconfig'   => (is => 'rw', isa => 'Int', default => 0, documentation => "the number of configurations found at each time step");
has 'r1'        => (is => 'rw', isa => 'Num', default => 0.0,);
has 'r2'        => (is => 'rw', isa => 'Num', default => 3.5,);
has 'r3'        => (is => 'rw', isa => 'Num', default => 5.2,);
has 'r4'        => (is => 'rw', isa => 'Num', default => 5.7,);
has 'beta'      => (is => 'rw', isa => 'Num', default => 20,);
has 'rbin'      => (is            => 'rw',
		    isa           => 'Num',
		    default       => 0.01,);
has 'betabin'   => (is            => 'rw',
		    isa           => 'Num',
		    default       => 0.5,);

has 'ss'        => (is => 'rw', isa => 'Bool', default => 0, trigger=>sub{my($self, $new) = @_; $self->ncl(0) if $new});
has 'ncl'       => (is => 'rw', isa => 'Bool', default => 0, trigger=>sub{my($self, $new) = @_; $self->ss(0)  if $new});

has 'timestep_count' => (is => 'rw', isa => 'Int',  default => 0);
has 'nearcl'      => (is => 'rw', isa => 'ArrayRef', default => sub{[]});


has 'sp'          => (is => 'rw', isa => Empty.'|Demeter::ScatteringPath', default => q{},);

## need a pgplot plotting template

sub rebin {
  my($self, $new) = @_;
  $self->_bin   if ($self->ss  and $self->update_bins);
  $self->_bin2d if ($self->ncl and $self->update_bins);
  return $self;
};

sub _number_of_steps {
  my ($self) = @_;
  open(my $H, '<', $self->file);
  my $count = 0;
  while (<$H>) {
    ++$count if m{\Atimestep};
  }
  #print $steps, $/;
  close $H;
  $self->nsteps($count);
  return $self;
};

sub _cluster {
  my ($self) = @_;
  $self->_number_of_steps;
  open(my $H, '<', $self->file);
  my @cluster = ();
  my @all = ();
  while (<$H>) {
    if (m{\Atimestep}) {
      push @all, [@cluster] if $#cluster>0;
      $#cluster = -1;
      next;
    };
    next if not m{\APt}; # skip the three lines trailing the timestamp
    my $position = <$H>;
    my @vec = split(' ', $position);
    push @cluster, \@vec;
    <$H>;
    <$H>;
    #my $velocity = <$H>;
    #my $force    = <$H>;
    #chomp $position;
  };
  push @all, [@cluster];
  $self->clusters(\@all);
  close $H;
  return $self;
};

sub rdf {
  my ($self) = @_;
  my @rdf = ();
  my $count = 0;
  my $rminsqr = $self->rmin*$self->rmin;
  my $rmaxsqr = $self->rmax*$self->rmax;
  $self->start_counter("Making RDF from each timestep", $#{$self->clusters}+1) if ($self->mo->ui eq 'screen');
  my ($x0, $x1, $x2) = (0,0,0);
  my @this;
  foreach my $step (@{$self->clusters}) {
    @this = @$step;
    $self->count if ($self->mo->ui eq 'screen');
    $self->timestep_count(++$count);
    $self->call_sentinal;
    foreach my $i (0 .. $#this) {
      ($x0, $x1, $x2) = @{$this[$i]};
      foreach my $j ($i+1 .. $#this) { # remember that all pairs are doubly degenerate
	my $rsqr = ($x0 - $this[$j]->[0])**2
	         + ($x1 - $this[$j]->[1])**2
	         + ($x2 - $this[$j]->[2])**2; # this loop has been optimized for speed, hence the weird syntax
	push @rdf, $rsqr if (($rsqr > $rminsqr) and ($rsqr < $rmaxsqr));
	#if (($i==1) and ($j==2)) {
	#  print join("|", @{$this[$i]}, @{$this[$j]}, $rsqr), $/;
	#};
      };
    };
  };
  if ($self->mo->ui eq 'screen') {
    $self->stop_counter;
    $self->start_spinner("Sorting RDF");
  };
  @rdf = sort { $a <=> $b } @rdf;
  $self->stop_spinner if ($self->mo->ui eq 'screen');
  $self->ssrdf(\@rdf);
  $self->npairs(($#rdf+1)/$self->nsteps);
  return $self;
};

sub nearly_collinear {
  my ($self) = @_;
  my $count = 0;
  my $r1sqr = $self->r1**2;
  my $r2sqr = $self->r2**2;
  my $r3sqr = $self->r3**2;
  my $r4sqr = $self->r4**2;

  $self->start_counter(sprintf("Making radial/angle distribution from every %d-th timestep", $self->skip), ($#{$self->clusters}+1)/$self->skip) if ($self->mo->ui eq 'screen');
  my ($x0, $x1, $x2) = (0,0,0);
  my ($ax, $ay, $az) = (0,0,0);
  my ($bx, $by, $bz) = (0,0,0);
  my ($cx, $cy, $cz) = (0,0,0);
  my @rdf1  = ();
  my @rdf4  = ();
  my @three = ();
  my $costh;
  my $i4;
  my $halfpath;
  my $cosbetamax = cos($PI*$self->beta/180);
  foreach my $step (@{$self->clusters}) {
    @rdf1 = ();
    @rdf4 = ();

    my @this = @$step;
    $self->timestep_count(++$count);
    next if ($count % $self->skip); # only process every Nth timestep
    $self->count if ($self->mo->ui eq 'screen');
    $self->call_sentinal;

    ## dig out the first and fourth coordination shells
    foreach my $i (0 .. $#this) {
      ($x0, $x1, $x2) = @{$this[$i]};
      foreach my $j (0 .. $#this) {
	next if ($i == $j);
	my $rsqr = ($x0 - $this[$j]->[0])**2
	         + ($x1 - $this[$j]->[1])**2
	         + ($x2 - $this[$j]->[2])**2; # this loop has been optimized for speed, hence the weird syntax
	push @rdf1, [sqrt($rsqr), $i, $j] if (($rsqr > $r1sqr) and ($rsqr < $r2sqr));
	push @rdf4, [sqrt($rsqr), $i, $j] if (($rsqr > $r3sqr) and ($rsqr < $r4sqr));
      };
    };

    ## find those 1st/4th pairs that share an absorber and have a small angle between them
    foreach my $fourth (@rdf4) {
      $i4 = $fourth->[1];
      foreach my $first (@rdf1) {
	next if ($i4 != $first->[1]);


	($ax, $ay, $az) = ($this[ $i4          ]->[0], $this[ $i4          ]->[1], $this[ $i4          ]->[2]);
	($bx, $by, $bz) = ($this[ $first->[2]  ]->[0], $this[ $first->[2]  ]->[1], $this[ $first->[2]  ]->[2]);
	($cx, $cy, $cz) = ($this[ $fourth->[2] ]->[0], $this[ $fourth->[2] ]->[1], $this[ $fourth->[2] ]->[2]);


	#my @vector = ( $cx-$bx, $cy-$by, $cz-$bz);
	my ($ct, $st, $cp, $sp)     = _trig( $cx-$bx, $cy-$by, $cz-$bz );
	#@vector    = ( $bx-$ax, $by-$ay, $bz-$az);
	my ($ctp, $stp, $cpp, $spp) = _trig( $bx-$ax, $by-$ay, $bz-$az);

	my $cppp = $cp*$cpp + $sp*$spp;
	my $sppp = $spp*$cp - $cpp*$sp;

	my $beta = $ct*$ctp + $st*$stp*$cppp;
	if ($beta < -1) {
	  $beta = "180.0000";
	} elsif ($beta >  1) {
	  $beta = "0.0000";
	} else {
	  $beta = sprintf("%.4f", 180 * acos($beta)  / $PI);
	};
	next if ($beta > $self->beta);

	my $leg2 = sqrt( ($this[ $first->[2] ]->[0] - $this[ $fourth->[2] ]->[0])**2 +
			 ($this[ $first->[2] ]->[1] - $this[ $fourth->[2] ]->[1])**2 +
			 ($this[ $first->[2] ]->[2] - $this[ $fourth->[2] ]->[2])**2 );
	$halfpath = ($leg2 + $first->[0] + $fourth->[0]) / 2;
	push @three, [$halfpath, $first->[0], $fourth->[0], $beta];

	#($a0, $a1, $a2) = ($this[ $i4 ]->[0], $this[ $i4 ]->[1], $this[ $i4 ]->[2]);
	#$costh =
 	#  (($this[ $first->[2] ]->[0] - $a0) * ($this[ $fourth->[2] ]->[0] - $a0) +
	#   ($this[ $first->[2] ]->[1] - $a1) * ($this[ $fourth->[2] ]->[1] - $a1) +
	#   ($this[ $first->[2] ]->[2] - $a2) * ($this[ $fourth->[2] ]->[2] - $a2))  / ($fourth->[0] * $first->[0]);
	#next if ($costh < $cosbetamax);
	#$halfpath = sqrt(($first->[0]*sin(acos($costh)))**2 + ($fourth->[0]-$first->[0]*$costh)**2);
	#push @three, [$halfpath, $first->[0], $fourth->[0], acos($costh)*180/$PI];
      };
    };
  };
  if ($self->mo->ui eq 'screen') {
    $self->stop_counter;
    $self->start_spinner("Sorting path length/angle distribution by path length");
  };
  @three = sort { $a->[0] <=> $b->[0] } @three;
  $self->stop_spinner if ($self->mo->ui eq 'screen');
  $self->nconfig( int( ($#three+1) / (($#{$self->clusters}+1) / $self->skip) + 0.5 ) );
  $self->nearcl(\@three);
};

sub _trig {
  my $TRIGEPS = 1e-6;
  my $rxysqr = $_[0]*$_[0] + $_[1]*$_[1];
  my $r   = sqrt($rxysqr + $_[2]*$_[2]);
  my $rxy = sqrt($rxysqr);
  my ($ct, $st, $cp, $sp) = (1, 0, 1, 0);

  ($ct, $st) = ($_[2]/$r,   $rxy/$r)    if ($r   > $TRIGEPS);
  ($cp, $sp) = ($_[0]/$rxy, $_[1]/$rxy) if ($rxy > $TRIGEPS);

  return ($ct, $st, $cp, $sp);
};

sub _bin {
  my ($self) = @_;
  my (@x, @y);
  my $bin_start = sqrt($self->ssrdf->[0]);
  my ($population, $average) = (0,0);
  $self->start_spinner(sprintf("Rebinning RDF into %.4f A bins", $self->bin)) if ($self->mo->ui eq 'screen');
  foreach my $pair (@{$self->ssrdf}) {
    my $rr = sqrt($pair);
    if (($rr - $bin_start) > $self->bin) {
      $average = $average/$population;
      push @x, sprintf("%.5f", $average);
      push @y, $population*2;
      #print join(" ", sprintf("%.5f", $average), $population*2), $/;
      $bin_start += $self->bin;
      $average = $rr;
      $population = 1;
    } else {
      $average += $rr;
      ++$population;
    };
  };
  push @x, sprintf("%.5f", $average);
  push @y, $population*2;
  $self->positions(\@x);
  $self->populations(\@y);
  $self->update_bins(0);
  $self->stop_spinner if ($self->mo->ui eq 'screen');
  return $self;
};

sub _bin2d {
  my ($self) = @_;

  $self->start_spinner(sprintf("Rebinning three-body configurations into %.3f A x %.2f deg bins", $self->rbin, $self->betabin)) if ($self->mo->ui eq 'screen');

  ## slice the configurations in R
  my @slices = ();
  my @this   = ();
  my $r_start = $self->nearcl->[0]->[0];
  my $aa = 0;
  foreach my $tb (@{$self->nearcl}) {
    my $rr = $tb->[0];
    if (($rr - $r_start) > $self->rbin) {
      push @slices, [@this];
      $r_start += $self->rbin;
      $#this=-1;
      push @this, $tb;
    } else {
      push @this, $tb;
    };
    ++$aa;
  };
  push @slices, [@this];
  #print ">>>>>>>>", $#slices+1, $/;

  ## pixelate each slice in angle
  my @plane = ();
  my @pixel = ();
  my $bb = 0;
  foreach my $sl (@slices) {
    my @slice = sort {$a->[3] <=> $b->[3]} @$sl; # sort by angle within this slice in R
    my $beta_start = 0;
    @pixel = ();
    foreach my $tb (@slice) {
      my $beta = $tb->[3];
      if (($beta - $beta_start) > $self->betabin) {
	push @plane, [@pixel];
	$beta_start += $self->betabin;
	@pixel = ();
	push @pixel, $tb;
      } else {
	push @pixel, $tb;
      };
      ++$bb;
    };
    push @plane, [@pixel];
  };
  ##print ">>>>>>>>", $#plane+1, $/;

  ## compute the population and average distance and angle of each pixel
  my @binned_plane = ();
  my ($r, $b, $l1, $l2, $count, $total) = (0, 0, 0, 0);
  my $cc = 0;
  foreach my $pix (@plane) {
    next if ($#{$pix} == -1);
    ($r, $b, $l1, $l2, $count) = (0, 0, 0);
    foreach my $tb (@{$pix}) {
      $r  += $tb->[0];
      $l1 += $tb->[1];
      #$l2 += $tb->[2];
      $b  += $tb->[3];
      ++$count;
      ++$total;
    };
    $cc += $count;
    push @binned_plane, [$r/$count, $b/$count, $l1/$count, $count];
  };
  $self->populations(\@binned_plane);
  $self->update_bins(0);
  $self->stop_spinner if ($self->mo->ui eq 'screen');
  printf "number of pixels: unbinned = %d    binned = %d\n", $#plane+1, $#binned_plane+1;
  printf "stripe pass = %d   pixel pass = %d    last pass = %d\n", $aa, $bb, $cc;
  printf "binned = %d  unbinned = %d\n", $total, $#{$self->nearcl}+1;
  return $self;
};

sub plot {
  my ($self) = @_;
  Ifeffit::put_array(join(".", $self->group, 'x'), $self->positions);
  Ifeffit::put_array(join(".", $self->group, 'y'), $self->populations);
  $self->po->start_plot;
  $self->dispose($self->template('plot', 'histo'), 'plotting');
  return $self;
};

sub histogram {
  my ($self) = @_;
  return if not $self->sp;
  my $histo = $self -> sp -> make_histogram($self->positions, $self->populations, q{}, q{});
  return $histo;
};

sub fpath {
  my ($self) = @_;
  my $histo = $self->histogram;
  my $composite = $self -> sp -> chi_from_histogram($histo);
  if ($self->ss) {
    my $text = sprintf("\n\ntaken from %d samples between %.3f and %.3f A\nbinned into %.4f A bins",
		       $self->get(qw{npairs rmin rmax bin}));
    $composite->pdtext($text);
  };
  return $composite;
};

__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

Demeter::ScatteringPath::Histogram::DL_POLY - Support for DL_POLY HISTORY file

=head1 VERSION

This documentation refers to Demeter version 0.4.

=head1 SYNOPSIS

=head1 DESCRIPTION

This provides support for importing data from the DL_POLY HISTORY
file, which is a format for providing the trajectory of a cluster
during a molecular dynamics simulation.  The DL_POLY website is
L<http://www.cse.scitech.ac.uk/ccg/software/DL_POLY/> and a
description of the HISTORY format is in section 5.2.1 of the User
Guide, a link to which can be found at the DL_POLY website.

The main purpose of this module is to extract the coordinates for a
given timestep from the history file and use those coordinates to
construct a histogram representation of that cluster for use in a fit
to EXAFS data using Demeter.

=head1 ATTRIBUTES

=over 4

=item C<file> (string)

The path to and name of the HISTORY file.  Setting this will trigger
reading of the file and construction of a histogram using the values
of the other attributes.

=item C<nsteps> (integer)

When the HISTORY file is first read, it will be parsed to obtain the
number of time steps contained in the file.  This number will be
stored in this attribute.

=item C<rmin> and C<rmax> (numbers)

The lower and upper bounds of the radial distribution function to
extract from the cluster.  These are set to values that include a
single coordination shell when constructing input for an EXAFS fit.
However, for constructing a plot of the RDF, it may be helpful to set
these to cover a larger range of distances.

=item C<bin> (number)

The width of the histogram bin to be extracted from the RDF.

=item C<sp> (number)

This is set to the L<Demeter::ScatteringPath> object used to construct
the bins of the histogram.  A good choice would be the similar path
from a Feff calculation on the bulk, crystalline analog to your
cluster.

=back

=head1 METHODS

=over 4

=item C<fpath>

Return a L<Demeter::FPath> object representing the sum of the bins of
the histogram extracted from the cluster.

=item C<histogram>

Return a reference to an array of L<Demeter::SSPath> objects
representing the bins of the histogram extracted from the cluster.

=item C<plot>

Make a plot of the the RDF.

=back

=head1 CONFIGURATION

See L<Demeter::Config> for a description of the configuration system.
Many attributes of a Data object can be configured via the
configuration system.  See, among others, the C<bkg>, C<fft>, C<bft>,
and C<fit> configuration groups.

=head1 DEPENDENCIES

Demeter's dependencies are in the F<Bundle/DemeterBundle.pm> file.

=head1 SERIALIZATION AND DESERIALIZATION

An XES object and be frozen to and thawed from a YAML file in the same
manner as a Data object.  The attributes and data arrays are read to
and from YAMLs with a single object perl YAML.

=head1 BUGS AND LIMITATIONS

=over 4

=item *

This currently only works for a monoatomic cluster.

=item *

Feff interaction is a bit unclear

=item *

Triangles and nearly colinear paths

=back

Please report problems to Bruce Ravel (bravel AT bnl DOT gov)

Patches are welcome.

=head1 AUTHOR

Bruce Ravel (bravel AT bnl DOT gov)

L<http://cars9.uchicago.edu/~ravel/software/>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2006-2011 Bruce Ravel (bravel AT bnl DOT gov). All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlgpl>.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut

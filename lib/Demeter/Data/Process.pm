package Demeter::Data::Process;

=for Copyright
 .
 Copyright (c) 2006-2019 Bruce Ravel (http://bruceravel.github.io/home).
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

use autodie qw(open close);

use Moose::Role;

use Carp;
use List::Util qw(reduce);
use List::MoreUtils qw(minmax firstval uniq);
use Demeter::Constants qw($EPSILON5 $NULLFILE);
#eval 'use PDL::Lite' if $Demeter::PDL_exists;
use PDL::Lite;
use PDL::Filter::Linear;
##use Storable qw(dclone);

sub rebin {
  my ($self, $rhash) = @_;
  #$$rhash{group} ||= q{};
  my $standard = $self->mo->standard;
  $self -> _update('fft');

  if (not $rhash) {
    my $persist = File::Spec->catfile(Demeter->dot_folder, "athena.column_selection");
    my $yaml = YAML::Tiny::Load(Demeter->slurp($persist));
    foreach my $p (qw(emin emax exafs pre xanes)) {
      $$rhash{$p} = $$rhash{$p}	                     # value passed
	         || $yaml->{"rebin_$p"}		     # value from most recent use in Athena
	         || $self->co->default("rebin", $p)  # user default
	         || $self->co->demeter("rebin", $p); # system default
    };
  };
  foreach my $k (keys %$rhash) {
    $self -> co -> set_default("rebin", $k, $$rhash{$k});
  };

  my @e = $self->fetch_array($self->group.".energy");
  my ($efirst, $elast) = ($e[0]+$self->bkg_eshift, $e[$#e]+$self->bkg_eshift);
  my @bingrid;

  ## pre edge region
  my $ee = $efirst;
  while ($ee < $self->co->default('rebin', 'emin')+$self->bkg_e0) {
    push @bingrid, $ee;
    $ee += $self->co->default('rebin', 'pre');
  };

  ## xanes region
  $ee = $self->co->default('rebin', 'emin')+$self->bkg_e0;
  while ($ee < $self->co->default('rebin', 'emax')+$self->bkg_e0) {
    push @bingrid, $ee;
    $ee += $self->co->default('rebin', 'xanes');
  };

  ## exafs region
  $ee = $self->co->default('rebin', 'emax')+$self->bkg_e0;
  my $kk = $self->e2k($self->co->default('rebin', 'emax'), 'rel');
  while ($ee < $elast) {
    push @bingrid, $ee;
    $kk += $self->co->default('rebin', 'exafs');
    $ee = $self->k2e($kk, 'abs');
  };
  push @bingrid, $elast;

  $self->dispense("process", "rebin_prep");
  $self->place_array('re___bin.eee', \@bingrid);
  ##print join("|", @bingrid), $/;

  my @x = $self->fetch_array($self->group.".xmu");
  my (@i,@s);
  my $pdl = PDL->new(\@x);
  my $n = $self->co->default('rebin', 'width');
  my $kernel = PDL::Core::ones($n) / $n;
  my $sm = $pdl->conv1d($kernel);
  my @z = $sm->list;
  if ($self->is_col) {
    ## i0 spectrum
    @i = $self->fetch_array($self->group.".i0");
    $pdl = PDL->new(\@i);
    $sm = $pdl->conv1d($kernel);
    my @ii = $sm->list;
    @ii = splice(@ii,1,-1);
    $self->place_array('re___bin.i0', \@ii);

    ## signal spectrum
    @s = $self->fetch_array($self->group.".signal");
    $pdl = PDL->new(\@s);
    $sm = $pdl->conv1d($kernel);
    my @ss = $sm->list;
    @ss = splice(@ss,1,-1);
    $self->place_array('re___bin.signal', \@ss);
  };

  @e = splice(@e,1,-1);
  @z = splice(@z,1,-1);
  $self->place_array('re___bin.energy', \@e);
  $self->place_array('re___bin.xmu', \@z);

  my $rebinned = $self->Clone;
  $self -> standard;		# make self the standard for rebinning
  $rebinned -> dispense("process", "rebin");
  $rebinned -> bkg_e0(0);

  ##$rebinned -> generated(1);
  $rebinned -> rebinned(1);
  $rebinned -> update_norm(1);
  $rebinned -> name($self->name . " rebinned");

  $rebinned->dispense("process", "deriv");
  $rebinned->resolve_defaults;
  $rebinned->datatype($self->datatype);
  $rebinned->bkg_eshift(0);	# the e0shift of the original data was removed by the rebinning procedure
  $rebinned->bkg_pre1($self->bkg_pre1);
  $rebinned->bkg_pre2($self->bkg_pre2);
  $rebinned->npts($#bingrid+1);
  $rebinned->xmin($bingrid[0]);
  $rebinned->xmax($bingrid[$#bingrid]);

  $rebinned->xdi_make_clone($self, "Data rebinned onto a three-region energy grid", 0) if (Demeter->xdi_exists);

  ##(ref($standard) =~ m{Data}) ? $standard->standard :
  $self->unset_standard;
  return $rebinned;
};

sub rebin_is_sensible {
  my ($self) = @_;
  my $ret = Demeter::Return -> new();

  my $emin  = $self->co->default(qw(rebin emin));
  my $emax  = $self->co->default(qw(rebin emax));
  if ($emax < $emin) {
    ($emin, $emax) = ($emax, $emin);
    $self->co->set_default(qw(rebin emin), $emin);
    $self->co->set_default(qw(rebin emax), $emax);
  };
  if ($emax == $emin) {
    $ret->status(0);
    $ret->message("The XANES region is of zero length (emin = emax)");
    return $ret;
  };

  my $pre   = $self->co->default(qw(rebin pre));
  if ($pre <= 0) {
    $ret->status(0);
    $ret->message("The pre-edge grid is zero or negative");
    return $ret;
  };

  my $xanes = $self->co->default(qw(rebin xanes));
  if ($xanes <= 0) {
    $ret->status(0);
    $ret->message("The XANES grid is zero or negative");
    return $ret;
  };

  my $exafs = $self->co->default(qw(rebin exafs));
  if ($exafs <= 0) {
    $ret->status(0);
    $ret->message("The EXAFS grid is zero or negative");
    return $ret;
  };

  return $ret;
};


  ## dispersive
  ## deconvolute
  ## self-absorption

=for LiteratureReference (merge)
  We also read in Pliny that the Dragons of Ethiopia often cross the Red
  Sea into Arabia, in search of better sources of nourishment.  In order
  to perform this feat, four or five Dragons "twist and interlace
  together like so many osiers in a hurdle."
                                   Jorge Luis Borges
                                   The Book of Imaginary Beings

=cut

## merge
sub merge {
  my ($self, $how, @data) = @_;
  $how = lc($how);
  ($how = 'k') if ($how eq 'c');
  ($how = 'e') if ($how eq 'x');
  croak("Demeter::Data::Process: \$data->merge(\$how, \@data) where \$how = e|k|n") if ($how !~ m{^[ekn]});

  my %howstring = (e => 'mu(E)', n => 'normalized mu(E)', k => 'chi(k)');

  my $standard = $self->mo->standard;
  $self->standard;		# make self the standard for merging

  my $merged = $self->Clone;
  $merged -> source($NULLFILE);
  $merged -> file($NULLFILE);
  $merged -> reference(q{});
  $merged -> generated(1);
  $merged -> prjrecord(q{});

  my $suff = ($how eq 'k') ? 'k' : 'energy';
  my $ndat = $self->get_array($suff); # in scalar context, returns # of data points
  my @used = ($self);
  my @excluded = ();
  foreach my $d (uniq($self, @data)) {
    next if $d eq $self;
    $d->_update('background') if ($how eq 'n');
    if ((($ndat - $d->get_array($suff)) > $d->co->default("merge", "short_data_margin")) and
	$d->co->default("merge", "exclude_short_data")) {
      push @excluded, $d;
      next;
    };
    push @used, $d;
  };


  my $sum = 0;
  foreach my $d (@used) {
    $d->_update('bft')        if ($d->mo->merge eq 'noise');
    $d->_update('background') if ($d->mo->merge eq 'step');
    my $weight = ($d->mo->merge eq 'importance') ? $d->importance
               : ($d->mo->merge eq 'noise')      ? $d->epsk
               : ($d->mo->merge eq 'step')       ? $d->bkg_step
	       :                                   $d->importance;
    ##print join("|", $d->name, $weight, $d->mo->merge), $/;
    $sum += $weight;
    $d->merge_weight($weight);
  };
  foreach my $d (@used) {
    $d->merge_weight($d->merge_weight / $sum);
  };

  if ($how =~ m{^k}) {
    $merged->datatype('chi');
    $self->mergek(@used);
  } elsif ($how =~ m{^e}) {
    ($self->datatype eq 'xanes') ? $merged->datatype('xanes') : $merged->datatype('xmu');
    $self->mergeE('x', @used);
  } elsif ($how =~ m{^n}) {
    ($self->datatype eq 'xanes') ? $merged->datatype('xanes') : $merged->datatype('xmu');
    $self->mergeE('n', @used);
  };

  my $ndata = $#used + 1;
  $self -> co -> set(ndata=>$ndata, weight=>1);

  my $string = $merged->template("process", "merge_norm"); #, {ndata=>$ndata});
  $self->dispose($string);

  $merged->mo->standard($merged);
  foreach my $d (@used) {
    next if (ref($d) !~ m{Data});
    my $string = $d->template("process", "merge_stddev");
    $self->dispose($string);
  };
  $string  = $merged->template("process", "merge_stddev_end");
  $string .= $merged->template("process", "merge_end");
  $self->dispose($string);
  #$merged -> set($self->metadata);
  $merged->xdi_make_clone($self, sprintf("Merge of %d scans", $#used+1), -1) if (Demeter->xdi_exists);

  if ($how !~ m{^k}) {
    $string  = $merged->template("process", "deriv");
    $self   -> dispose($string);
    $merged -> update_norm(1);
    $merged -> initialize_e0;
  } else {
    $merged -> update_norm(0);
  };
  $merged -> is_merge($how);
  $merged -> update_fft(1);
  $merged -> bkg_e0($self->bkg_e0);
  $merged -> bkg_eshift(0);
  $merged -> i0_string(q{});
  $merged -> provenance("Merge of  " . join(', ', map {$_->name} (@used))   );
  $merged -> source("Merge of  " . join(', ', map {$_->name} (@used))   );
  $merged -> name("data merged as " . $howstring{$how});
  ($how =~ m{^k}) ? $merged -> datatype('chi') : $merged -> datatype('xmu');
  if ($#excluded != -1) {
    $merged->annotation("These groups were excluded (see sec 9.3.3 of the user manual) from the merge for being too short: " . join(", ", map {$_->name} @excluded));
  };

  (ref($standard) =~ m{Data}) ? $standard->standard : $self->unset_standard;
  return $merged;
};
sub mergeE {
  my ($self, $how, @data) = @_;
  carp("Demeter::Data::Process::mergeE: first argument MUST be x or n.\n\n") if ($how !~ m{^[nx]});
  $self -> _update("normalize")  if ($how eq 'x');
  $self -> _update("background") if ($how eq 'n');


  my ($emin, $emax) = (-1e10, 1e10);
  ## make an array in the m___erge group containing the longest common range of data
  foreach my $d (@data) {
    next if (ref($d) !~ m{Data});
    my @array = $d->get_array("energy");
    $d -> _update("normalize")  if ($how eq 'x');
    $d -> _update("background") if ($how eq 'n');
    ($emin = $array[0])  if ($array[0]  > $emin);
    ($emax = $array[-1]) if ($array[-1] < $emax);
  };
  my $config = $self->mo->config;
  $config -> set(merge_min   => $emin,
		 merge_max   => $emax,
		 merge_space => "energy",
		 merge_data  => ($how eq 'x') ? "xmu" : 'norm',
		);
  my $string = $self->template("process", "merge_subarray");
  $string   .= $self->template("process", "merge_start");
  $self->dispose($string);

  #foreach my $d (uniq($self, @data)) {
  foreach my $d (@data) {
    next if (ref($d) !~ m{Data});
    my $string = $d->template("process", "merge_interp");
    $string   .= $d->template("process", "merge");
    $self->dispose($string);
  };
};
sub mergek {
  my ($self, @data) = @_;
  $self -> _update("fft");

  my ($kmin, $kmax) = (-1e10, 1e10);
  ## make an array in the m___erge group containing the longest common range of data
  foreach my $d (uniq($self, @data)) {
    next if (ref($d) !~ m{Data});
    $d -> _update("fft");
    my @array = $d->get_array("k");
    #print join("|", "----------", $d, $array[0], $array[-1]), $/;
    ($kmin = $array[0])  if ($array[0]  > $kmin);
    ($kmax = $array[-1]) if ($array[-1] < $kmax);
  };
  my $config = $self->mo->config;
  $config -> set(merge_min   => $kmin,
		 merge_max   => $kmax,
		 merge_space => "k",
		 merge_data  => 'chi',
		);
  my $string = $self->template("process", "merge_subarray");
  $string   .= $self->template("process", "merge_start");
  $self->dispose($string);

  foreach my $d (@data) {
    next if (ref($d) !~ m{Data});
    my $string = $d->template("process", "merge_interp");
    $string   .= $d->template("process", "merge");
    $self->dispose($string);
  };
};


=for LiteratureReference (truncate)
  Tunk-Poj pursued the Antelope across the entire firmament.  Finally,
  the Antelope, exhausted, fell to the earth and Tunk-Poj cut off its
  two hind legs. "Men," he said, "are growing smaller and weaker every
  day.  How can they hunt Six-Legged Antelopes if I myself can barely
  catch them?"  Since that day, antelopes have had four legs.
                                      Jorge Luis Borges
                                      The Book of Imaginary Beings

=cut

sub Truncate {
  my ($self, $beforeafter, $value) = @_;
  if ($self->datatype =~ m{(?:xmu|xanes)}) {
    $self -> _update("normalize");
    $self -> mo -> config -> set(trun_x => 'energy', 'trun_y' => 'xmu');
  } elsif ($self->datatype eq "chi") {
    $self -> mo -> config -> set(trun_x => 'k', 'trun_y' => 'chi');
  };				# also not_data, trun_y can be something else
  $self -> mo -> config -> set(trun_ba => (lc($beforeafter) =~ m{\Ab}) ? 'before' : 'after',
				 trun_value => $value);

  my $string = q{};
  if (lc($beforeafter) =~ m{\Ab}) { # truncate preceding values
    $string  = $self->template("process", "truncate_before");
    $string .= $self->template("process", "trun_signal_before") if ($self->datatype =~ m{(?:xmu|xanes)});
  } else {			    # truncate following values
    $string  = $self->template("process", "truncate_after");
    $string .= $self->template("process", "trun_signal_after")  if ($self->datatype =~ m{(?:xmu|xanes)});
  };
  $self->dispose($string);

  ## flag data for reprocessing
  if ($self->datatype =~ m{(?:xmu|xanes)}) {
    $self->update_norm(1);
  } elsif ($self->datatype eq "chi") {
    $self->update_fft(1);
  };
};



=for LiteratureReference (deglitch)
  The Hsing-tien is a headless creature that fought against the gods
  and was decapitated; it has remained ever afterward headless.  Its
  eyes are in its breast and its mouth is its navel.  It hops and
  skips through the open countryside, brandishing its axe and its
  shield.
                                      T'ai Kuang Chi in
                                      Jorge Luis Borges'
                                      The Book of Imaginary Beings

=cut

sub deglitch {
  my ($self, @values) = @_;
  carp("$self is not mu(E) data\n\n"), return if ($self->datatype !~ m{xmu|xanes});
  $self -> _update("normalize");
  my @x = $self->get_array("energy");
  foreach my $v (@values) {
    carp("$v is not within the data range of $self\n\n"), next if (($v < $x[0]) or ($v > $x[-1]));
    my $nearest = reduce { abs($a-$v) < abs($b-$v) ? $a : $b } @x;
    if (($nearest <= $x[2]) and (not $self->is_larch)) {
      $self -> Truncate("before", $x[3]);
    } elsif (($nearest >= $x[-2]) and (not $self->is_larch)) {
      $self -> Truncate("after", $x[-3]);
    } else {
      $self -> mo -> config -> set(degl_point => $nearest);
      my $string = $self->template("process", "deglitch");
      $self->dispose($string);
    };
  };
  $self->update_norm(1); # flag for reprocessing
};


sub deglitch_margins {
  my ($self) = @_;
  my @energy = $self->get_array('energy');
  my @xmu    = $self->get_array('xmu');
  my @me     = $self->get_array('menergy');
  my @m1     = $self->get_array('margin1');
  my @m2     = $self->get_array('margin2');

  my $j = 0;
  my @points = ();
  foreach my $i (0 .. $#energy) {
    next if ($energy[$i] < $me[0]);    # before margin range
    last if ($energy[$i] > $me[$#me]); # after margin range
    push @points, $energy[$i] if (($xmu[$i] > $m1[$j]) or ($xmu[$i] < $m2[$j]));
    ++$j;
  };
  $self->deglitch(@points);
  return $self;
};


sub smooth {
  my ($self, $n, $how) = @_;
  ($n = 1) if ($n < 1);
  ($n = 1) if $self->is_larch;
  $how ||= $self->datatype;
  if ($how =~ m{(?:xmu|xanes)}) {
    $self -> _update("normalize");
    $self -> mo -> config -> set(smooth_suffix => 'xmu');
  } elsif ($how eq "chi") {
    $self -> mo -> config -> set(smooth_suffix => 'chi');
  };
  foreach (1 .. int($n)) {
    my $string = $self->template("process", "smooth");
    $self->dispose($string);
  };
  # flag for reprocessing
  if ($how =~ m{(?:xmu|xanes)}) {
    $self->update_norm(1);
  } elsif ($how eq "chi") {
    $self->update_fft(1);
  };
};

sub boxcar {
  my ($self, $n, $how) = @_;
  # if (not $Demeter::PDL_exists) {
  #   print "hi\n";
  #   $self->smooth($n, $how);
  #   return;
  # };
  ($n = 11) if ($n < 1);
  $n = $n+1 if (not $n%2);
  $how ||= $self->datatype;

  my (@x, $pdl);
  if ($how =~ m{(?:xmu|xanes)}) {
    $self -> _update("normalize");
    @x = $self->get_array('energy');
    $pdl = PDL->new($self->ref_array('xmu'));
  } elsif ($how eq "chi") {
    $self -> _update("fft");
    @x = $self->get_array('k');
    $pdl = PDL->new($self->ref_array('chi'));
  };

  my $kernel = PDL::Core::ones($n) / $n;
  my $sm = $pdl->conv1d($kernel);
  my @z = $sm->list;

  splice(@x, 0, ($n-1)/2);
  @x = splice(@x, 0, $#x-($n-1)/2);
  splice(@z, 0, ($n-1)/2);
  @z = splice(@z, 0, $#z-($n-1)/2);

  my $smoothed = $self->put(\@x, \@z, datatype=>'xmu', name=>$self->name.", boxcar size $n", bkg_eshift=>$self->bkg_eshift);
  $smoothed->e0($self);
  $smoothed->resolve_defaults;
  # flag for reprocessing
  if ($how =~ m{(?:xmu|xanes)}) {
    $smoothed->update_norm(1);
  } elsif ($how eq "chi") {
    $smoothed->update_fft(1);
  };
  $smoothed->xdi_make_clone($self, 'Smoothed data by boxcar average', 0) if (Demeter->xdi_exists);

  return $smoothed;
};

sub gaussian_filter {
  my ($self, $n, $sd, $how) = @_;
  # if (not $Demeter::PDL_exists) {
  #   print "hi\n";
  #   $self->smooth($n, $how);
  #   return;
  # };
  ($n = 11) if ($n < 1);
  $n = $n+1 if (not $n%2);
  ($sd = 4) if ($sd < 1);
  $how ||= $self->datatype;

  my (@x, $pdl);
  if ($how =~ m{(?:xmu|xanes)}) {
    $self -> _update("normalize");
    @x = $self->get_array('energy');
    $pdl = PDL->new($self->ref_array('xmu'));
  } elsif ($how eq "chi") {
    $self -> _update("fft");
    @x = $self->get_array('k');
    $pdl = PDL->new($self->ref_array('chi'));
  };

  my $filter = PDL::Filter::Gaussian->new($n,$sd);
  my ($sm, $corr) = $filter->predict($pdl);
  my @z = $sm->list;

  splice(@x, 0, ($n-1)/2);
  @x = splice(@x, 0, $#x-($n-1)/2);
  #splice(@z, 0, ($n-1)/2);
  @z = splice(@z, 0, $#z);

  my $smoothed = $self->put(\@x, \@z, datatype=>'xmu', name=>$self->name.", Gaussian filter $n, $sd", bkg_eshift=>$self->bkg_eshift);
  $smoothed->e0($self);
  $smoothed->resolve_defaults;
  # flag for reprocessing
  if ($how =~ m{(?:xmu|xanes)}) {
    $smoothed->update_norm(1);
  } elsif ($how eq "chi") {
    $smoothed->update_fft(1);
  };
  $smoothed->xdi_make_clone($self, 'Smoothed data by Gaussian filter', 0) if (Demeter->xdi_exists);
  return $smoothed;
};

sub convolve {
  my ($self, @args) = @_;
  my $config = $self->mo->config;;
  #croak("usage: \$self->convolve(width=>\$width, type=>\$type, which=>\$which)"), return
  #  if (ref($args) !~ /HASH/);
  my %args = @args;
  $args{width} ||= 0;
  ($args{width}  = 0) if ($args{width} < 0);
  $args{type}  ||= $config->default("convolve", "type");
  $args{type}    = lc($args{type});
  ($args{type}   = $config->default("convolve", "type")) if ($args{type} !~ m{\A[gl]});
  $args{which} ||= 'xmu';
  $args{which}   = lc($args{which});
  ($args{which}  = 'xmu')      if ($args{type} !~ m{\A[cx]});
  if ($args{which} eq 'xmu') {
    $self -> _update("normalize");
  };
  $config->set(conv_type  => $args{type},
	       conv_width => $args{width},
	       conv_which => $args{which},
	      );
  my $string = $self->template("process", "convolve");
  $self->dispose($string);
  if ($args{which} eq 'xmu') {
    $self->update_norm(1);
  } elsif ($args{which} eq 'chi') {
    $self->update_fft(1);
  };
};


sub deconvolve {
  my ($self, @args) = @_;
  my $config = $self->mo->config;
  #croak("usage: \$self->deconvolve(width=>\$width, type=>\$type, which=>\$which)"), return
  #  if (ref($args) !~ /HASH/);
  my %args = @args;
  $args{width} ||= 0;
  ($args{width}  = 0) if ($args{width} < 0);
  $args{type}  ||= $config->default("convolve", "type");
  $args{type}    = lc($args{type});
  ($args{type}   = $config->default("convolve", "type")) if ($args{type} !~ m{\A[gl]});
  $args{which} ||= 'xmu';
  $args{which}   = lc($args{which});
  ($args{which}  = 'xmu')      if ($args{type} !~ m{\A[cx]});
  if ($args{which} eq 'xmu') {
    $self -> _update("normalize");
  };
  $config->set(conv_type  => $args{type},
	       conv_width => $args{width},
	       conv_which => $args{which},
	      );
  my $string = $self->template("process", "deconvolve");
  $self->dispose($string);
  if ($args{which} eq 'xmu') {
    $self->update_norm(1);
  } elsif ($args{which} eq 'chi') {
    $self->update_fft(1);
  };
};




=for LiteratureReference (noise)
  No one seems to ever have seen [a Banshee]; they are less a shape
  than a wailing that lends horror to the nights of Ireland and
  ... the mountain regions of Scotland.
                                 Jorge Luis Borges
                                 The Book of Imaginary Beings

=cut

sub noise {
  my ($self, @args) = @_;
  my $config = $self->mo->config;;
  #croak("usage: \$self->convolve({width=>\$width, which=>\$which})"), return
  #  if (ref($args) !~ /HASH/);
  my %args = @args;
  $args{noise} ||= 0;
  ($args{noise}  = 0) if ($args{noise} < 0);
  $args{which} ||= 'xmu';
  $args{which}   = lc($args{which});
  ($args{which}  = 'xmu') if ($args{which} ne 'chi');
  if ($args{which} eq 'xmu') {
    $self -> _update("normalize");
    $args{noise} *= $self->bkg_step;
  } else {
    $self -> _update("fft");
  };
  $config -> set(noise_level => $args{noise},
		 noise_which => $args{which},
		);
  my $string = $self->template("process", "noise");
  $self->dispose($string);
  if ($args{which} eq 'xmu') {
    $self->update_norm(1);
  } elsif ($args{which} eq 'chi') {
    $self->update_fft(1);
  };
};


sub interpolate {
  my ($self, @data) = @_;

};


sub mee {
  my ($self, @args) = @_;
  my %args = @args;
  $args{width} ||= 0;
  $args{shift} ||= 0;
  $args{amp}   ||= 1;
  $args{how}   ||= 'reflect';	# reflect | arctan
  $args{amp}   = 0    if $args{amp}   < 0;
  $args{width} = 0.01 if $args{width} < 0.01;
  $args{how}   = 'reflect' if $args{how} !~ m{arctan}i;
  $self->_update('background');
  if ($args{how} =~ m{reflect}i) {
    $self->dispense('process', 'mee_reflect', {width=>$args{width}, amp=>$args{amp}, shift=>$args{shift}});

    my @x = $self->fetch_array($self->group.'.energy');
    my @y = $self->fetch_array('m___ee.xint');
    my $e1 = $x[0] + $args{shift};
    my $yoff = 0;
    foreach my $i (0 .. $#x) {
      if ($x[$i] < $e1) {
	## this replaces the extrapolated part of the shifted spectrum
	## with zeros in the pre-edge
	$yoff = $y[$i];
	$y[$i] = 0;
      } else {
	## this corrects for the pre-edge not going to the baseline
	## after the convolution and approximately corrects the edge
	## step of the convoluted mu(E) data
	## $y[$i] = ($y[$i] - $yoff);# * (1 + $yoff);
      };
    };
    $self->place_array("m___ee.xint", \@y);
  } elsif ($args{how} =~ m{arctan}i) {
    $self->dispense('process', 'mee_arctan',  {width=>$args{width}, shift=>$args{shift}});
  };

  my $new = $self->Clone;
  $new   -> name($new->name . ' (MEE)');
  $new   -> standard;
  $self  -> dispense('process', 'mee_do', {amp=>$args{amp}});
  $new   -> unset_standard;

  $new->xdi_make_clone($self, 'Removed multi-electron excitation', 0) if (Demeter->xdi_exists);

  return $new;
};


1;


=head1 NAME

Demeter::Data::Process - Processing XAS data

=head1 VERSION

This documentation refers to Demeter version 0.9.26.

=head1 DESCRIPTION

This subclass of L<Demeter::Data> contains methods for calibrating
mu(E) data and adjusting e0.

=head1 METHODS

Note that these data processing methods are not reversable (without
reimporting the data).  Many of the examples suggest the use of the
C<clone> method for easy comparison between the processed and original
data.  In those cases cloning is a good idea because the methods
B<will> alter the arrays in the data processing backend
(Ifeffit/Larch).

=over 4

=item C<rebin>

This method rebins EXAFS data onto a standard EXAFS grid defined by
parameters that can be passed to the method via an anonymous hash.  It
returns the reference to the new object and creates an appropriate set
of arrays.  The new object is a clone of the original object.

  $rebinned_group = $data -> rebin(pre=>-35, xanes=>0.3);
  $rebinned_group -> plot('E');

The parameter hash can contain zero or more of these parameters:

=over 4

=item I<group>

The group name of the newly created group containing the rebinned
data.  The default is to generate a unique group name.

=item I<emin>

The boundary between the pre-edge and XANES regions, expressed in
relative energy.  The default is -30 eV.

=item I<emin>

The boundary between the XANES and EXAFS regions, expressed in
relative energy.  The default is 50 eV.

=item I<pre>

The grid size in energy of the rebinned pre-edge region.  The default
is 10 eV.

=item I<xanes>

The grid size in energy of the rebinned XANES region.  The default is
0.5 eV.

=item I<exafs>

The grid size in wavenumber of the rebinned EXAFS region.  The default
is 0.07 inverse Angstrom.

=back

See L<Demeter::Config> and the rebin configuration group for
details about configuring the defaults.

=item C<merge>

This method merges a list of data groups.  The merge can be done in
mu(E), norm(E), or chi(k).  A list of Data objects will be
interpolated onto the energy (or k) grid of C<$data> and merged along
with C<$data>.

  $merged_group = $data->merge('e', @groups);

The first argument is C<e>, C<n>, or C<k>.  The remaining arguments
are Data objects to be included in the merge.

=item C<Truncate>

Truncate data before or after a given value.  This discards the
truncated points from the arrays in the data processing backend
(Ifeffit/Larch).

  $data -> Truncate("after", 7700);

The truncation is exclusive -- that is the value closest in energy or
k to the supplied value remains in the array.

This is capitalized to avoid confusion with the perl built-in.

=item C<deglitch>

Remove a single data points -- glitches -- from the data.  This only
works on mu(E) data and a check is made that the supplied values are
within the data range.

  $data -> deglitch(17385.686);

or

  $data -> deglitch(@spurious_points);

In each case, the points closest in energy to the supplied values are
removed.  Glitches are simply removed from the data -- no
interpolation between surrounding values is made.

There is no method explicitly intended to find a glitchy point.  That
is left as a chore for the user interface.

Due to a quirk in Ifeffit (or perhaps in my understanding of Ifeffit)
attempting to deglitch any of the last two points of data will result
in both points being removed.  The same is true of the first two
points.  This is a bug, but not, I don't think, a horrible one.

=item C<smooth>

Perform three-point smoothing on the mu(E) or chi(k) data, as
appropriate.  The argument tells Demeter how many times to reapply the
smoothing.

  $copy = $data -> Clone;
  $copy -> smooth(5);

=item C<convolve>

Perform a Gaussian or Lorentzian convolution on the data.  Becuase
this has a number of possible arguments, named arguments in an
anonymous hash are used.  The width is sigma as defined in the data
processing backend (Ifeffit/Larch) and is a possitive number.  A
negative number will be interpretted as zero.  The type is either
"Gaussian" or "Lorentzian".  The type is either "xmu" or "chi" -- that
is convolute mu(E) or chi(k) data.

  $copy = $data -> Clone;
  $copy -> convolve(width=>2, type=>'gaussian', which=>'xmu');

=item C<noise>

Add noise to a mu(E) or chi(k) spectrum.

  $copy = $data -> Clone;
  $copy -> noise(noise=>0.02, which=>'xmu');

The amount of noise is intepretted differently for mu(E) data as for
chi(k).  For chi(k) data, the supplied noise used as the RMS value of
the noise to be applied to the un-weighted chi(k) data.  Consequently,
you probably want to use a small value -- probably something on the
order of 0.001.

For mu(E) data, the noise is interpretted as a fraction of the edge
step.  Thus the noise level for a given value scales with the size of
the edge step.  A value of 0.02, as in the example above, is 2% of the
edge step.

=back

=head1 CONFIGURATION

See L<Demeter::Config> for a description of the configuration system.

=head1 DEPENDENCIES

Demeter's dependencies are in the F<Build.PL> file.

=head1 BUGS AND LIMITATIONS

=over 4

=item *

The merge method does not yet return the varience array.

=item *

Adding noise to chi(k) is not working correctly.  (But adding noise to
mu(E) does.)

=back

Please report problems to the Ifeffit Mailing List
(L<http://cars9.uchicago.edu/mailman/listinfo/ifeffit/>)

Patches are welcome.

=head1 AUTHOR

Bruce Ravel, L<http://bruceravel.github.io/home>

L<http://bruceravel.github.io/demeter/>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2006-2019 Bruce Ravel (L<http://bruceravel.github.io/home>). All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlgpl>.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut

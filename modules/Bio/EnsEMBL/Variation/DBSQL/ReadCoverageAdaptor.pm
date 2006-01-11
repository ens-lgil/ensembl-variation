#
# Ensembl module for Bio::EnsEMBL::Variation::DBSQL::ReadCoverageAdaptor
#
# Copyright (c) 2005 Ensembl
#
# You may distribute this module under the same terms as perl itself
#
#

=head1 NAME

Bio::EnsEMBL::Variation::DBSQL::ReadCoverageAdaptor

=head1 SYNOPSIS

  $vdb = Bio::EnsEMBL::Variation::DBSQL::DBAdaptor->new(...);
  $db  = Bio::EnsEMBL::DBSQL::DBAdaptor->new(...);

  # tell the variation database where core database information can be
  # be found
  $vdb->dnadb($db);

  $rca = $vdb->get_ReadCoverageAdaptor();
  $sa  = $db->get_SliceAdaptor();
  $pa  = $vdb->get_PopulationAdaptor();


  # get read coverage in a region for a certain population in in a certain level
  $slice = $sa->fetch_by_region('chromosome', 'X', 1e6, 2e6);
  $population = $pa->fetch_by_name("UNKNOWN");
  $level = 1;
  foreach $rc (@{$vfa->fetch_all_by_Slice_Sample_depth($slice,$population,$level)}) {
    print $rc->start(), '-', $rc->end(), "\n";
  }


=head1 DESCRIPTION

This adaptor provides database connectivity for ReadCoverage objects.
Coverage information for reads can be obtained from the database using this
adaptor.  See the base class BaseFeatureAdaptor for more information.

=head1 AUTHOR - Daniel Rios

=head1 CONTACT

Post questions to the Ensembl development list ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Variation::DBSQL::ReadCoverageAdaptor;

use Bio::EnsEMBL::Variation::ReadCoverage;
use Bio::EnsEMBL::Mapper::RangeRegistry;
use Bio::EnsEMBL::DBSQL::BaseFeatureAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(throw);

our @ISA = ('Bio::EnsEMBL::DBSQL::BaseFeatureAdaptor');

=head2 fetch_all_by_Slice_Sample_depth

    Arg[0]      : Bio::EnsEMBL::Slice $slice
    Arg[1]      : (optional) Bio::EnsEMBL::Variation::Sample $sample
    Arg[2]      : (optional) int $level
    Example     : my $features = $rca->fetch_all_by_Slice_Sample_depth($slice,$sample,$level); or
                  my $features = $rca->fetch_all_by_Slice_Sample_depth($slice, $sample); or
                  my $features = $rca->fetch_all_by_Slice_Sample_depth($slice, $level); or
                  my $features = $rca->fetch_all_by_Slice_Sample_depth($slice); 
    Description : Gets all the read coverage features for a given sample(strain or individual) in a certain level
                  in the provided slice
    ReturnType  : listref of Bio::EnsEMBL::Variation::ReadCoverage
    Exceptions  : thrown on bad arguments
    Caller      : general

=cut

sub fetch_all_by_Slice_Sample_depth{
    my $self = shift;
    my $slice = shift;
    my @args = @_; #can contain individual and/or level

    if(!ref($slice) || !$slice->isa('Bio::EnsEMBL::Slice')) {
	throw('Bio::EnsEMBL::Slice arg expected');
    }

    if (defined $args[0]){ #contains, at least, 1 parameter, either a Individual or the level
	my $constraint;
	if (defined $args[1]){ #contains both parameters, first the Individual and second the level
	    if(!ref($args[0]) || !$args[0]->isa('Bio::EnsEMBL::Variation::Sample')) {
		throw('Bio::EnsEMBL::Variation::Sample arg expected');
	    }
	    if(!defined($args[0]->dbID())) {
		throw("Sample arg must have defined dbID");
	    }
	    $constraint = "rc.sample_id = " . $args[0]->dbID . " AND rc.level = " . $args[1];
	}
	else{ #there is just 1 argument, can either be the Individual or the level
	    if (!ref($args[0])){
		#it should just contain the level
		$constraint = "rc.level = " . $args[0];
	    }
	    else{
		#it should contain the Individual
		if (!$args[0]->isa('Bio::EnsEMBL::Variation::Sample')){
		    throw('Bio::EnsEMBL::Variation::Sample arg expected');
		}
		$constraint = "rc.sample_id = " . $args[0]->dbID;
	    }
	}

	return $self->fetch_all_by_Slice_constraint($slice,$constraint);    
    }
    #call the method fetch_all_by_Slice
    return $self->fetch_all_by_Slice($slice);    
}

#returns a list of regions that are covered by all the sample given
sub fetch_all_regions_covered{
    my $self = shift;
    my $slice = shift;
    my $samples = shift;  #listref of sample names to get the coverage from

    my $population_adaptor = $self->db->get_PopulationAdaptor;
    my $range_registry = [];
    my $max_level = scalar(@{$samples});
    _initialize_range_registry($range_registry,$max_level);
    foreach my $sample_name (@{$samples}){
	my $sample = $population_adaptor->fetch_by_name($sample_name);
	my $coverage = $self->fetch_all_by_Slice_Sample_depth($slice,$sample,1); #get coverage information
	foreach my $cv_feature (@{$coverage}){
	    my $range = [$cv_feature->seq_region_start,$cv_feature->seq_region_end]; #store toplevel coordinates
	    _register_range_level($range_registry,$range,1,$max_level);	   
	}
    }
    return $range_registry->[$max_level]->get_ranges(1);
}

=head2 fetch_coverage_levels

    Args        : none
    Example     : my @coverage_levels = @{$rca->fetch_coverage_levels()};
    Description : Gets the read coverage depths calculated in the database
    ReturnType  : listref of integer
    Exceptions  : none
    Caller      : general

=cut

sub get_coverage_levels{
    my $self = shift;
    my @levels;
    my $level_coverage;
    my $sth = $self->prepare(qq{SELECT meta_value from meta where meta_key = 'coverage_level'
				});
    $sth->execute();
    $sth->bind_columns(\$level_coverage);
    while ($sth->fetch()){
	push @levels, $level_coverage;
    }
    $sth->finish();

    return \@levels;
}

sub _initialize_range_registry{
    my $range_registry = shift;
    my $max_level = shift;

    foreach my $level (1..$max_level){
	$range_registry->[$level] = Bio::EnsEMBL::Mapper::RangeRegistry->new();
    }

    return;
}


sub _register_range_level{
    my $range_registry = shift;
    my $range = shift;
    my $level = shift;
    my $max_level = shift;
    
    return if ($level > $max_level);
    my $rr = $range_registry->[$level];
    my $pair = $rr->check_and_register(1,$range->[0],$range->[1]);
    my $pair_inverted = _invert_pair($range,$pair);
    return if (!defined $pair_inverted);
    foreach my $inverted_range (@{$pair_inverted}){
	_register_range_level($range_registry,$inverted_range,$level+1, $max_level);
    }
}

#for a given range and the one covered, returns the inverted
sub _invert_pair{
    my $range = shift; #initial range of the array
    my $pairs = shift; #listref with the pairs that have been added to the range

    my @inverted_pairs;
    my $inverted;

    my $rr = Bio::EnsEMBL::Mapper::RangeRegistry->new();

    foreach my $pair (@{$pairs}){
	$rr->check_and_register(1,$pair->[0],$pair->[1]);
    }
    return $rr->check_and_register(1,$range->[0],$range->[1]); #register again the range
}

sub _tables{ return (['read_coverage','rc']
		     )}


sub _columns{
    return qw (rc.seq_region_id rc.seq_region_start rc.seq_region_end rc.level rc.sample_id);
}


sub _objs_from_sth{
  my ($self, $sth, $mapper, $dest_slice) = @_;
  
  my $sa = $self->db()->dnadb()->get_SliceAdaptor();

  #
  # This code is ugly because an attempt has been made to remove as many
  # function calls as possible for speed purposes.  Thus many caches and
  # a fair bit of gymnastics is used.
  #

  my ($seq_region_id, $seq_region_start, $seq_region_end, $level, $sample_id);
  my $seq_region_strand = 1; #assume all reads are in the + strand

  $sth->bind_columns(\$seq_region_id, \$seq_region_start, \$seq_region_end, \$level, \$sample_id);

  my @features;
  my %seen_pops;  #hash containing the populations seen
  my %slice_hash;
  my %sr_name_hash;
  my %sr_cs_hash;
  my $asm_cs;
  my $cmp_cs;
  my $asm_cs_vers;
  my $asm_cs_name;
  my $cmp_cs_vers;
  my $cmp_cs_name;

  if($mapper) {
      $asm_cs = $mapper->assembled_CoordSystem();
      $cmp_cs = $mapper->component_CoordSystem();
      $asm_cs_name = $asm_cs->name();
      $asm_cs_vers = $asm_cs->version();
      $cmp_cs_name = $cmp_cs->name();
      $cmp_cs_vers = $cmp_cs->version();
  }
  
  my $dest_slice_start;
  my $dest_slice_end;
  my $dest_slice_strand;
  my $dest_slice_length;

  if($dest_slice) {
      $dest_slice_start  = $dest_slice->start();
      $dest_slice_end    = $dest_slice->end();
      $dest_slice_strand = $dest_slice->strand();
      $dest_slice_length = $dest_slice->length();
  }

  my $read_coverage;
  FEATURE: while ($sth->fetch()){

      #get the population_adaptor object
      my $pa = $self->db()->get_PopulationAdaptor();

      #get the slice object
      my $slice = $slice_hash{"ID:".$seq_region_id};
      if(!$slice) {
	  $slice = $sa->fetch_by_seq_region_id($seq_region_id);
	  $slice_hash{"ID:".$seq_region_id} = $slice;
	  $sr_name_hash{$seq_region_id} = $slice->seq_region_name();
	  $sr_cs_hash{$seq_region_id} = $slice->coord_system();
      }
      #
      # remap the feature coordinates to another coord system
      # if a mapper was provided
      #
      if($mapper) {
	  my $sr_name = $sr_name_hash{$seq_region_id};
	  my $sr_cs   = $sr_cs_hash{$seq_region_id};
	  
	  ($sr_name,$seq_region_start,$seq_region_end,$seq_region_strand) =
	      $mapper->fastmap($sr_name, $seq_region_start, $seq_region_end,
			       $seq_region_strand, $sr_cs);
	  
	  #skip features that map to gaps or coord system boundaries
	  next FEATURE if(!defined($sr_name));
	  
	  #get a slice in the coord system we just mapped to
	  if($asm_cs == $sr_cs || ($cmp_cs != $sr_cs && $asm_cs->equals($sr_cs))) {
	      $slice = $slice_hash{"NAME:$sr_name:$cmp_cs_name:$cmp_cs_vers"} ||=
		  $sa->fetch_by_region($cmp_cs_name, $sr_name,undef, undef, undef,
				       $cmp_cs_vers);
	  } else {
	      $slice = $slice_hash{"NAME:$sr_name:$asm_cs_name:$asm_cs_vers"} ||=
		  $sa->fetch_by_region($asm_cs_name, $sr_name, undef, undef, undef,
				       $asm_cs_vers);
	  }
      }
      
      #
      # If a destination slice was provided convert the coords
      # If the dest_slice starts at 1 and is foward strand, nothing needs doing
      #
      if($dest_slice) {
	  if($dest_slice_start != 1 || $dest_slice_strand != 1) {
	      if($dest_slice_strand == 1) {
		  $seq_region_start = $seq_region_start - $dest_slice_start + 1;
		  $seq_region_end   = $seq_region_end   - $dest_slice_start + 1;
	      } else {
		  my $tmp_seq_region_start = $seq_region_start;
		  $seq_region_start = $dest_slice_end - $seq_region_end + 1;
		  $seq_region_end   = $dest_slice_end - $tmp_seq_region_start + 1;
		  $seq_region_strand *= -1;
	      }
	      
	      #throw away features off the end of the requested slice
	      if($seq_region_end < 1 || $seq_region_start > $dest_slice_length) {
		  next FEATURE;
	      }
	  }
	  $slice = $dest_slice;
      }

      my $sample;
      if($sample_id){
	  $sample = $seen_pops{$sample_id} ||= $pa->fetch_by_dbID($sample_id);
      }
      $read_coverage = Bio::EnsEMBL::Variation::ReadCoverage->new(-start => $seq_region_start,
								  -end   => $seq_region_end,
								  -slice => $slice,
								  -adaptor  => $self,
								  -level => $level,
								  -sample => $sample,
								  );
      push @features, $read_coverage;
  }
  $sth->finish();
  return \@features;
}

1;

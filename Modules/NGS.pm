package NGS;
# package for NGS processing
# Author: xwang
use strict;
use File::Basename;
use File::Path qw(make_path);
use Carp;
use Data::Dumper;

sub new {
	my $self = shift;
	my %h = (
		java=>'java',
		samtools=>'samtools',
		bedtools=>'bedtools',
		bwa=>'bwa',
		prinseq=>'prinseq-lite.pl',
		verbose=>1,
		@_, 
	);	
	bless \%h, $self;
}

## trim reads with sickle. 
sub trim_reads {
	my $self = shift;
	my %h = (
		read2_inf => "", # read2 input file
		read2_outf=>"", # read2 outfile
		singles_outf=>"",  # singles outfile
		trim_logf=>"", 
		param=>"",
		scheme=>"sanger",  # quality score scheme
		sickle=>'sickle',
		@_,   # read1_inf, read1_outf 
	);
		
	required_args(\%h, 'read1_inf', 'read1_outf');
		
	my $endtype= $h{read2_inf}? "pe" : "se";
	if ( $endtype eq "pe" ) {
		required_args(\%h, 'read2_outf' )
	}

	my $cmd = "$h{sickle} $endtype -t $h{scheme} -f $h{read1_inf} -g -o $h{read1_outf}";
	if ( $endtype eq "pe" ) {
		$h{singles_outf} //= "$h{read1_outf}.singles.fastq.gz";

		$cmd .= " -r $h{read2_inf} -p $h{read2_outf} -s $h{singles_outf}";
	}

	$cmd .= " $h{param}" if $h{param};
	$cmd .= " > $h{trim_logf}" if $h{trim_logf};

	print STDERR "$cmd\n" if $self->{verbose};
	return system($cmd);
}

sub create_bam {
	my $self = shift;
	my %h = ( 
		read2_inf=>'', # read2 input file
		picard=>'', # picard path, required if mark_duplicate=1
		mark_duplicate=>0,

		abra=>'',  # ABRA jar file, required if realign_indel=1	
		target_bed=>'', # e.g. amplicon bed file, required for indel realignment
		realign_indel=>0,
		ref_fasta=>'',  # reference fasta file

		remove_duplicate=>0,
		@_
	);	

	required_args(\%h, 'sample', 'read1_inf', 'idxbase', 'bam_outf');

	# bam_outf is final bam file

	$self->bwa_align(read1_inf=>$h{read1_inf},
    	read2_inf=>$h{read2_inf}, id=>$h{sample}, sm=>$h{sample},
    	idxbase=>$h{idxbase},
    	bam_outf=>$h{bam_outf});


	## Indel realignment 
	if ( $h{realign_indel} && $h{abra} && $h{target_bed} && $h{ref_fasta} ) {
		$self->ABRA_realign(bam_inf=>$h{bam_outf}, abra=>$h{abra},
        	target_bed=>$h{target_bed}, ref_fasta=>$h{ref_fasta});
	}

	## Mark duplicates
	if ( $h{mark_duplicate} or $h{remove_duplicate} ) {
		$self->mark_duplicate(bam_inf=>$h{bam_outf}, picard=>$h{picard});
	}

	my @bam_stats = $self->bamReadCount($h{bam_outf});	

	if ( $h{remove_duplicate} ) {
		print STDERR "Removing duplicates.\n";
		$self->remove_duplicate($h{bam_outf});
	}
	$self->index_bam($h{bam_outf});

	return @bam_stats;
}

## bwa alignment with bwa mem, and sort/index
## Removing non-primary and supplemental alignment entries
sub bwa_align {
	my $self = shift;
	my %h = ( 
		read2_inf=>"", # read2 input file
		param=>"-t 4 -M",
		id=>'', # read group ID
		sm=>'', # read group sample name
		pl=>'ILLUMINA', # read group platform
		@_
	);	

	required_args(\%h, 'read1_inf', 'idxbase', 'bam_outf');
	my $samtools = $self->{samtools};
	my $cmd = "$self->{bwa} mem $h{idxbase} $h{read1_inf}";

	if ($h{read2_inf}) {
		$cmd .= " $h{read2_inf}";
	}

	if ( $h{param} ) {
		$cmd .= " $h{param}";
	}

	if ($h{id} && $h{sm}) {
		$cmd .= " -R \'\@RG\tID:$h{id}\tSM:$h{sm}\tPL:$h{pl}\'";
	}

	$cmd .= " |$samtools view -S -b -F 256 -";
	$cmd .= " |$samtools view -b -F 2048 -"; 
	$cmd .= " |$samtools sort -f - $h{bam_outf} && $samtools index $h{bam_outf}";
	$cmd = "($cmd) &> $h{bam_outf}.bwa.log";
	print STDERR "$cmd\n" if $self->{verbose};
	return system($cmd);	
}

## sort reads in bam. If bam_outf is not specified, 
## the input bam is replaced.
## Required arguments: bam_inf
## Optional arguments: bam_outf
sub sort_index_bam {
	my $self = shift;
	my %h = ( @_ );
	required_args(\%h, 'bam_inf');
	my $samtools = $self->{samtools};
	my $cmd;
	if ( $h{bam_outf} ) {
		$cmd = "$samtools sort -f $h{bam_inf} $h{bam_outf}";
		$cmd .= " && $samtools index $h{bam_outf}"; 
	} else {
		$cmd = "mv $h{bam_inf} $h{bam_inf}.tmp";
		$cmd .= " && $samtools sort -f $h{bam_inf}.tmp $h{bam_inf}";
		$cmd .= " && $samtools index $h{bam_inf}";
		$cmd .= " && rm $h{bam_inf}.tmp";
	}

	print STDERR "$cmd\n" if $self->{verbose};
	return system($cmd);
}


## Create index for bam. 
## Required arguments: bam_inf
## The resulting index file is <bamfile>.bai. If bam file is x.bam, then index is x.bam.bai
sub index_bam {
	my ($self, $bamfile) = @_;
	my $cmd = "$self->{samtools} index $bamfile";
	return system($cmd);
}

## mark duplicate reads in bam
## Required arguments: bam_inf
## Optional arguments: bam_outf
## Bam index created by picard for x.bam is x.bai, inconsistent with samtools index. 
sub mark_duplicate {
	my $self = shift;
	my %h = (
		metrics=>'.md.metrics',
		bam_outf=>'',
		@_, 
	);

	required_args(\%h, 'bam_inf', 'picard');

	my $prog = $h{picard} . "/MarkDuplicates.jar";
	croak "Cannot find $prog" if !-f $prog;
	
	my $cmd;
	if ( $h{bam_outf} ) {
		$cmd = "$self->{java} -jar $prog I=$h{bam_inf} O=$h{bam_outf} METRICS_FILE=$h{bam_outf}" . $h{metrics};
	} else {
		$cmd = "mv $h{bam_inf} $h{bam_inf}.tmp";
		$cmd .= " && $self->{java} -jar $prog I=$h{bam_inf}.tmp O=$h{bam_inf} METRICS_FILE=$h{bam_inf}" . $h{metrics};
	}

	$cmd .= " REMOVE_DUPLICATES=false ASSUME_SORTED=true";
	$cmd .= " VALIDATION_STRINGENCY=LENIENT CREATE_INDEX=false";
	$cmd .= " MAX_FILE_HANDLES_FOR_READ_ENDS_MAP=1000";
	$cmd .= " TMP_DIR=$self->{tmpdir}";

	if ( $h{bam_outf} ) {
		$cmd .= " && $self->{samtools} index $h{bam_outf}";
	} else {
		$cmd .= " && rm $h{bam_inf}.tmp";
		$cmd .= " && $self->{samtools} index $h{bam_inf}";
	}

	$cmd = "($cmd) &> $h{bam_inf}.md.log";
	print STDERR "$cmd\n" if $self->{verbose};
	return system($cmd);	
}

## Update bam file with ABRA indel detection
## Required arguments: bam_inf, target_bed, ref_fasta, 
## Optional arguments: bam_outf 
sub ABRA_realign {
	my $self = shift;
	my %h = ( 
		bam_outf=>'',
		@_	
	);

	required_args(\%h, 'bam_inf', 'abra', 'target_bed', 'ref_fasta');
	croak "Cannot find ABRA jar file" if !-f $h{abra};
	
	my $tmpdir = $self->{tmpdir}; 

	my $workdir = "$tmpdir/" . basename($h{bam_inf});
	
	my $replace_flag = 0;
	if ( !$h{bam_outf} ) {
		$replace_flag = 1;
		$h{bam_outf} = "$h{bam_inf}.tmp.bam";
	}

	# ABRA requires that tmpdir does not exist and input bam file is already indexed.
	my $cmd = "rm -rf $workdir && mkdir -p $workdir"; 
	$cmd .= " && $self->{java} -Djava.io.tmpdir=$tmpdir -jar $h{abra} --threads 2";
	$cmd .= " --ref $h{ref_fasta} --targets $h{target_bed} --working $workdir";
	$cmd .= " --in $h{bam_inf} --out $h{bam_outf}";
	$cmd .= " && rm -r $workdir";

	if ( $replace_flag) {
		$cmd .= " && mv $h{bam_outf} $h{bam_inf}";
	}
	
	$cmd = "($cmd) &> $h{bam_inf}.abra.log";
	print STDERR "$cmd\n" if $self->{verbose};

	system($cmd);
	if ( $replace_flag ) {
		return $self->sort_index_bam(bam_inf=>$h{bam_inf});
	} else {
		return $self->sort_index_bam(bam_inf=>$h{bam_outf});
	}
}

sub remove_duplicate {
	my ($self, $inbam, $outbam) = @_;

	my $replace = 0;
	if (!$outbam) {
		$outbam = "$inbam.tmp";
		$replace = 1;
	}

	my $status = system("$self->{samtools} view -b -F 1024 $inbam > $outbam");
	if ( $status == 0 && $replace== 1 ) {
		rename($outbam, $inbam);
	}
}

## Count reads in fastq file. If it's gzipped, set gz=1
sub fastqReadCount {
	my ($self, $fastq_file, $gz) = @_;
	my $cmd = $gz? "gunzip -c $fastq_file|wc -l" : "wc -l $fastq_file";
	my $result = qx($cmd);
	chomp $result;
	return $result/4;
}


## Obtain read counts from bam file.
## The bam file should be marked duplicates.
## In order to count reads in a region (chr, start, end), the bam file must be indexed.  
## The start and end are 1-based chromosome position.
sub bamReadCount {
	my ($self, $bamfile) = @_;
	my $cmd = $self->{samtools} . " view -c $bamfile";
		
	my $bam_reads = qx($cmd 2>/dev/null);
	my $mapped_reads = qx($cmd -F 4 2>/dev/null);
	my $duplicate_reads = qx($cmd -f 1024 2>/dev/null);
	chomp $bam_reads;
	chomp $mapped_reads;
	chomp $duplicate_reads;
	my $uniq_reads = $mapped_reads - $duplicate_reads;

	return ($bam_reads, $mapped_reads, $duplicate_reads, $uniq_reads);
}

## start and and are 1-based and inclusive.
## bedtools must be at least version 2
sub regionReadCount {
	my $self = shift;
	my %h = (min_overlap=>1, @_);
	required_args(\%h, 'bam_inf', 'chr', 'start', 'end');
 
	my $cnt = 0;
	if ( $h{min_overlap}==1 ) {
		$cnt = qx($self->{samtools} view -c $h{bam_inf} $h{chr}:$h{start}-$h{end} 2>/dev/null);
	} else {
		my $ratio = $h{min_overlap}/($h{end} - $h{start} + 1);
		my $bedfile="$h{bam_inf}.tmp.region.bed";
		$self->makeBed($h{chr}, $h{start}, $h{end}, $bedfile);
		my $cmd = "$self->{bedtools} intersect -a $h{bam_inf} -b $bedfile -F $ratio -u";
		$cmd .= " | $self->{samtools} view -c - "; 
		$cnt = qx($cmd);
		unlink $bedfile;
	}
	chomp $cnt;
	return $cnt;
}

## create a bed file, with 0-based coordinates: [start coord, end coord).
## start and end is 1-based.
sub makeBed {
	my ($self, $chr, $start, $end, $outfile) = @_;
	open(my $outf, ">$outfile") or die $!;	
	print $outf join("\t", $chr, $start-1, $end)."\n";
	close $outf;
}

## Count reads in different stages
## start and end are 1-based.
sub readFlow {
	my $self = shift;
	my %h = ( gz=>1, r2_fastq_inf=>'',
		# Below are required for region read count	 
		chr=>'', start=>0, end=>0, bam_inf=>'',  
		min_overlap=>1, 
		@_);

	required_args(\%h, 'r1_fastq_inf',  'bamstat_aref', 'sample', 'outfile');

	open(my $cntf, ">$h{outfile}") or die $!;
	print $cntf join("\t", "Sample", "RawReads", "QualityReads", "MappedReads", 
			"PctMap", "Duplicates", "PctDup", "UniqueReads", "RegionReads") . "\n";

	my $raw_reads = $self->fastqReadCount($h{r1_fastq_inf}, $h{gz});
	if ( $h{r2_fastq_inf} ) {
		$raw_reads +=  $self->fastqReadCount($h{r2_fastq_inf}, $h{gz});
	}

	my ($bam_reads, $mapped_reads, $duplicate_reads, $uniq_reads)= @{$h{bamstat_aref}};
	my $pct_map = $bam_reads > 0 ? sprintf("%.2f", 100*$mapped_reads/$bam_reads) : "NA";
	my $pct_dup = $bam_reads > 0 ? sprintf("%.2f", 100*$duplicate_reads/$bam_reads) : "NA";

	my $region_reads = "NA";
	if ( $h{chr} && $h{start} && $h{end} && $h{bam_inf} ) {
		$region_reads =	$self->regionReadCount(bam_inf=>$h{bam_inf}, 
			chr=>$h{chr}, start=>$h{start}, end=>$h{end}, 
			min_overlap=>$h{min_overlap});
	}

	print $cntf join("\t", $h{sample}, $raw_reads, $bam_reads, $mapped_reads,
        	$pct_map, $duplicate_reads, $pct_dup, $uniq_reads, $region_reads) . "\n";
	close $cntf;
}

# Calculate the number of reads aligned on different chromosomes
sub chromCount {
	my ($self, $bamfile, $outfile) = @_;
	my $cmd = "$self->{samtools} view $bamfile | cut -f 3 | sort | uniq -c | sed 's/^[ ]*//'";
	print STDERR "$cmd\n" if $self->{verbose};
	qx($cmd >$outfile);
}


## Create variant stat file from bam file
sub variantStat {
	my $self = shift;
	my %h = (
		max_depth=>1000000,
		window_size=>1,
		type=>'variation',
		chr=>'',
		start=>0,
		end=>0,
		pysamstats=>'pysamstats',
		@_,	
	);	

	required_args(\%h, 'bam_inf', 'ref_fasta', 'outfile'); 
	my $cmd = "$h{pysamstats} --type $h{type} --max-depth $h{max_depth}";
	$cmd .= " --window-size $h{window_size} --fasta $h{ref_fasta}";
	if ( $h{chr} && $h{start} > 0 && $h{end} > 0 ) {
		$cmd .= " --chromosome $h{chr} --start $h{start} --end $h{end}";	
	}
	$cmd .= " $h{bam_inf} --output $h{outfile}";
	
	print STDERR "$cmd\n" if $self->{verbose};
	
	return system($cmd);		
}

sub required_args {
	my $href = shift;
	foreach my $arg ( @_ ) {
		if (!defined $href->{$arg}) {
			croak "Missing required argument: $arg";
		} 
	}
}


## Find reads that overlap with the target region. 
## start and end are 1-based and inclusive.
sub targetSeq {
	my $self = shift;
	my %h = (
		min_mapq=>0,
		min_overlap=>1,
		target_name=>'',  # DGKA_CR1
		ref_name=>'', # hg19
		sample_name=>'',
		@_	
	);

	required_args(\%h, 'bam_inf', 'chr', 'target_start', 'target_end', 
		'outfile_detail', 'outfile_count', 'outfile_allele');

	open(my $outf, ">$h{outfile_detail}") or croak $!;
	open(my $cntf, ">$h{outfile_count}") or croak $!;
	open(my $alef, ">$h{outfile_allele}") or croak $!;

	print $outf join("\t", "ReadName", "TargetSeq", "IndelStr", "Strand") . "\n";
	print $cntf join("\t", "Sample", "Reference", "CrisprSite", "CrisprRegion", "TargetReads", 
			"WtReads", "IndelReads", "PctWt", "PctIndel", "InframeIndel", "PctInframeIndel") . "\n";
	print $alef join("\t", "Sample", "Reference", "CrisprSite", "CrisprRegion", "WtIndel", 
		"Reads", "Pct", "IndelLength", "FrameShift") . "\n"; 

	#my $cmd = "$self->{samtools} view $h{bam_inf} $h{chr}:$h{target_start}-$h{target_end}";
	my $ratio = $h{min_overlap}/($h{target_end} - $h{target_start} + 1);
	my $bedfile="$h{bam_inf}.tmp.target.bed";
	$self->makeBed($h{chr}, $h{target_start}, $h{target_end}, $bedfile);
	my $cmd = "$self->{bedtools} intersect -a $h{bam_inf} -b $bedfile -F $ratio -u";
	$cmd .= " | $self->{samtools} view -";
	print STDERR "$cmd\n" if $self->{verbose};

	open(P, "$cmd|") or die $!;

	# reads overlapping target region that meet min_mapq and min_overlap
	my $overlap_reads = 0; 

	# among total reads, those with at least 1 base of indel inside target region.
	my $indel_reads = 0; 

	my $inframe_indel_reads = 0;

	my %freqs; # frequencies of alleles
	
	while (my $line=<P>) {
		my ($qname, $flag, $chr, $align_start, $mapq, $cigar, 
			$mate_chr, $mate_start, $tlen, $seq, $qual ) = split(/\t/, $line);

		next if $mapq < $h{min_mapq};  

		my $chr_pos = $align_start -1;  # pos on chromosome
		my $seq_pos = 0; # position on read sequence
	
		# split cigar string between number and letter
		my @cig = split(/(?<=\d)(?=\D)|(?<=\D)(?=\d)/, $cigar);			

		my $indelstr='';
		my $indel_length = 0;

		# read sequence comparable to reference but with insertion removed and deletion added back.
		my $read_ref_seq;

		for (my $i=0; $i< @cig-1; $i +=2 ) {
			my $len = $cig[$i];
			my $letter=$cig[$i+1];
			if ( $letter eq "S" ) {
				$seq_pos += $len;
			} elsif ( $letter eq "M" ) {
				$read_ref_seq .= substr($seq, $seq_pos, $len);
				$seq_pos += $len;
				$chr_pos += $len;
			} elsif ( $letter eq "D" ) {
				$read_ref_seq .= '-' x $len;
				my $del_start = $chr_pos+1;
				$chr_pos += $len;

				# keep the deletion if it overlaps the target region by 1 base.
				if ( _isOverlap($h{target_start}, $h{target_end},
					$del_start, $chr_pos, 1)) {
					$indelstr .= "$del_start:$chr_pos:D::";
					$indel_length += -$len;
				} 
			} elsif ( $letter eq "I" ) {
				my $inserted_seq = substr($seq, $seq_pos, $len);
				$seq_pos += $len;

				# keep the insertion if it overlaps the target region by 1 base. 
				if ( _isOverlap($h{target_start}, $h{target_end},
					$chr_pos, $chr_pos+1, 1) ) {
					$indelstr .= $chr_pos . ":" . ($chr_pos+1) . ":I:$inserted_seq:";
					$indel_length += $len;
				}
			}			
		} # end for

		# target sequence
		my $target_seq = substr($read_ref_seq, $h{target_start} - $align_start, 
			$h{target_end} - $h{target_start} + 1);

		$overlap_reads ++;

		if ($indelstr) {
			$indel_reads ++;  
			$indelstr=~ s/:$//;
			$inframe_indel_reads  ++ if $indel_length % 3 == 0;
			$freqs{$indelstr}++;
		} else {
			$freqs{WT}++;
		}

		my $strand = $flag & 16 ? '-' : '+';
		print $outf join("\t", $qname, $target_seq, $indelstr, $strand)  . "\n";
	} # end while

	#unlink $bedfile;
	return if !$overlap_reads; 

	## Output read counts

	my $wt_reads = $overlap_reads - $indel_reads;
	my $pct_wt = sprintf("%.2f", $wt_reads * 100/$overlap_reads);
	my $pct_indel = sprintf("%.2f", 100 - $pct_wt);
	my $pct_inframe = sprintf("%.2f", $inframe_indel_reads * 100/$overlap_reads);
	
	print $cntf join("\t", $h{sample_name}, $h{target_name}, $h{ref_name}, 
		"$h{chr}:$h{target_start}-$h{target_end}", 
		$overlap_reads, $wt_reads, $indel_reads, $pct_wt, $pct_indel,
		$inframe_indel_reads, $pct_inframe) . "\n";

	## Output allele frequencies in descending order
	foreach my $key (sort {$freqs{$b}<=>$freqs{$a}} keys %freqs) {
		my $reads = $freqs{$key};
		my $pct = sprintf("%.2f", $reads * 100 /$overlap_reads);

		my $indel_len = 0;  
		my $frame_shift = "N";
		if ( $key ne "WT" ) {
			$indel_len = _getIndelLength($key);
			$frame_shift = $indel_len%3 ? "Y" : "N";
		} 

		print $alef join("\t", $h{sample_name}, $h{target_name}, $h{ref_name}, 
			"$h{chr}:$h{target_start}-$h{target_end}", 
			$key, $reads, $pct, $indel_len, $frame_shift) . "\n";
	}
}

sub _getIndelLength {
	my $indelstr = shift;
	## e.g. 56330828:56330829:D::56330837:56330838:I:CCC
	my @a = split(/:/, $indelstr);
	my $len = 0;
	for (my $i=0; $i<@a; $i +=4) {
		if ( $a[$i+2] eq "D" ) {
			$len -= $a[$i+1] - $a[$i] + 1;
		} elsif ( $a[$i+2] eq "I" ) { 		
			$len += length($a[$i+3]);
		}
	}
	return $len;
}

sub _isOverlap {
	my ($subj_start, $subj_end, $query_start, $query_end, $min_overlap) = @_;
	$min_overlap //= 1;

	my %subj;
	for (my $i=$subj_start; $i<=$subj_end; $i++) {
		$subj{$i}=1;
	}

	my $overlap = 0;
	for (my $i=$query_start; $i<= $query_end; $i++) {
		$overlap ++ if $subj{$i}; 	
	}

	return $overlap >= $min_overlap? 1:0;
}

## HDR homology directed repair
## base_changes is a comma-separated strings of positons and bases. Format: <pos><base>,...
## for example, 101900208C,101900229G,101900232C,101900235A. Bases are on positive strand, and 
## are intended new bases, not reference bases. 
sub categorizeHDR {
	my $self = shift;
	my %h = (
		min_mapq=>0,
		@_	
	);

	required_args(\%h, 'bam_inf', 'chr', 'base_changes', 'sample_name', 'stat_outf');

	my $sample = $h{sample_name};
	my $chr = $h{chr};

	# intended base changes	
	my %alt; # pos=>base
	foreach my $mut (split /,/, $h{base_changes}) {
		my ($pos, $base) = ( $mut =~ /(\d+)(\D+)/ );
		$alt{$pos} = uc($base); 
	}

	my $outdir = dirname($h{stat_outf});
	make_path($outdir);

	# create bed file spanning the HDR SNPs. Position format: [Start, end).
	my $bedfile="$outdir/$sample.hdr.bed";
	my @pos = sort {$a <=> $b} keys %alt;
	my $hdr_start = $pos[0];
	my $hdr_end = $pos[-1];
	$self->makeBed($chr, $hdr_start, $hdr_end, $bedfile);

	# create bam file containing HDR bases.
	my $hdr_bam = "$outdir/$sample.hdr.bam";

	my $samtools = $self->{samtools};
	my $cmd = "$self->{bedtools} intersect -a $h{bam_inf} -b $bedfile -F 1 -u";
	$cmd .= " > $hdr_bam && samtools index $hdr_bam";
	print STDERR "$cmd\n" if $self->{verbose};
	die "Failed to create $hdr_bam\n" if system($cmd);

	## create HDR seq file
	my $hdr_seq_file = "$outdir/$sample.hdr.seq";
	_extractHDRseq($hdr_bam, $hdr_start, $hdr_end, $hdr_seq_file, $h{min_mapq});

	## parse HDR seq file to categorize HDR
	my %alts; # key position is offset by $start
	foreach my $coord ( keys %alt ) {
		$alts{$coord - $hdr_start}=$alt{$coord};
	}
		
	my @p = sort {$a <=> $b} keys %alts;
	my $snps = scalar(@p);# number of intended base changes	
	my $total = 0; # total reads
	my $perfect_oligo = 0; # perfect HDR reads.
	my $edit_oligo = 0; # reads with 1 or more desired bases, but also width indels 
	my $partial_oligo = 0; # reads with some but not all desired bases, no indel.
	my $non_oligo = 0; # reads without any desired base changes, regardless of indel 

	open( my $inf, $hdr_seq_file) or die $!;
	while ( my $line = <$inf> ) {
		next if $line !~ /\w/;
		chomp $line;
		my ($qname, $hdr_seq, $insertion) = split(/\t/, $line);
		my $isEdited = 0;
		if ( $insertion =~ /I/ or $hdr_seq =~ /\-/ ) {
			$isEdited = 1;
		}
		
		my @bases = split(//, $hdr_seq);
		my $alt_cnt = 0; # snp base cnt
		foreach my $i ( @p ) {
			if ( $bases[$i] eq $alts{$i} ) {
				$alt_cnt++;
			}	
		}			

		if ( $alt_cnt == 0 ) {
			$non_oligo ++;
			print STDERR "$line\tNonOligo\n" if $h{verbose};
		} else {
			if ( $isEdited ) {
				$edit_oligo ++;
				print STDERR "$line\tEdit\n" if $h{verbose};
			} else {
				if ( $alt_cnt == $snps ) {
					$perfect_oligo ++;
					print STDERR "$line\tPerfect\n" if $h{verbose};	
				} else {
					$partial_oligo ++;
					print STDERR "$line\tPartial\n" if $h{verbose};
				} 
			}	
		}

		$total ++;

	} # end while

	open(my $outf, ">$h{stat_outf}") or die $!;
	
	my @cnames = ("PerfectOligo", "EditedOligo", "PartialOligo", "NonOligo");
	my @pct_cnames;
	foreach my $cn (@cnames) {
		push (@pct_cnames, "Pct$cn");
	}

	my @values = ($perfect_oligo, $edit_oligo, $partial_oligo, $non_oligo);
	my @pcts;
	foreach my $v ( @values ) {
		push(@pcts, $total? sprintf("%.2f", $v*100/$total) : 0 );
	}	

	print $outf join("\t", "Sample", "TotalReads", @cnames, @pct_cnames) . "\n";
	print $outf join("\t", $sample, $total, @values, @pcts) . "\n";

	close $outf;
}

# read the bam entries and categorize the HDRs
# start, end are 1-based inclusiv. They are the first and last position 
# of intended base change region of HDR
sub _extractHDRseq{
	my ($hdr_bam, $hdr_start, $hdr_end, $out_hdr_seq, $min_mapq) = @_;

	open(my $seqf, ">$out_hdr_seq") or die $!;
	open(my $pipe, "samtools view $hdr_bam|") or die $!;
	while (my $line=<$pipe>) {
		my ($qname, $flag, $chr, $align_start, $mapq, $cigar,
			$mate_chr, $mate_start, $tlen, $seq, $qual ) = split(/\t/, $line);
		next if $min_mapq && $mapq < $min_mapq;
		my $chr_pos = $align_start -1;  # pos on chromosome
		my $seq_pos = 0; # position on read sequence

		my @bases = split(//, $seq);
		my $newseq; # new seq, but with deletion filled with -, and with insertion and soft clip removed.
		my %insertions; # record the inserted sequence at certain chrosome position.	
		my $offset = $hdr_start - $align_start;

		# split cigar string between number and lette
		my @cig = split(/(?<=\d)(?=\D)|(?<=\D)(?=\d)/, $cigar);
		
		for (my $i=0; $i< @cig-1; $i +=2 ) {
			my $len = $cig[$i];
			my $letter=$cig[$i+1];
			if ( $letter eq "S" ) {
				$seq_pos += $len;
			} elsif ( $letter eq "M" ) {
				$newseq .= substr($seq, $seq_pos, $len);
				$seq_pos += $len;
				$chr_pos += $len;
			} elsif ( $letter eq "D" ) {
				$newseq .= '-' x $len;
				$chr_pos += $len;
			} elsif ( $letter eq "I" ) {
				$insertions{$chr_pos - ($hdr_start-1)} = substr($seq, $seq_pos, $len);
				$seq_pos += $len;
			}
		}

		## sequence for the HDR spanning region
		my $hdr_len = $hdr_end - $hdr_start + 1;
		my $hdr_seq = substr($newseq, $offset, $hdr_len); 

		my $inserted_seqstr = '';
		# p is 0-based.
		foreach my $p ( sort {$a<=>$b} keys %insertions ) {
			if ( defined $p && $p >= 0 && $p < $hdr_len ) {
				$inserted_seqstr .= $p . ":I:" . $insertions{$p} . ",";
			} 
		} 
		if ( $inserted_seqstr ) {
			$inserted_seqstr =~ s/,$//;
		}

		print $seqf join("\t", $qname, $hdr_seq, $inserted_seqstr) . "\n";		
	}
	close $pipe;
	close $seqf;
}

## return a command to filter bam file
sub getBamFilterCommand {
	my $self = shift;
	my %h = (
		non_primary=>1,
		non_supplementary=>1,
        non_dup=>1,
		mapped=>1,
        @_,
    );
	required_args(\%h, 'bam_inf');	

	my %flags = (non_primary=>256, non_supplementary=>2048, non_dup=>1024, aligned=>4);
	my @values; # would have (256, 2048, 1024, 4) depending on the options

	foreach my $opt ( keys %flags ) {			
		if ( $h{$opt} ) {
			push (@values, $flags{$opt});
		}
	}

	my $cmd;
	for ( my $i=0; $i < @values; $i++ ) {
		my $file = $i ? '-' : $h{bam_inf};
		if ( $cmd ) {
			$cmd .= "|";
		}
		$cmd .= "$self->{samtools} view -b -F $values[$i] $file";
	} 
	return $cmd;	
}

sub filter_fastq {
	my ($self, %h) = @_;
	my $outdir = $h{filter_dir};
	my $filter_param = $h{filter_param};
	my $b = $self->{prinseq};
	$self->assert_prog($b);
	my $ext = $h{ext};
	
	croak "Must have outdir. ext defaults to fastq.gz\n" if (!$outdir);
	make_path($outdir) if !-d $outdir;
	$ext =~ s/^\.// if $ext;  # remove the front . if there.
	$ext //= "fastq.gz";
	
	my $f = $h{read1};
	my $f2 = $h{read2};
	
	croak "Read1 file variable has no value.\n" if (!$f);
	
	basename($f) =~ /(.*)\.$ext/;
	my $stem = $1;
	
	(my $sample=$stem) =~ s/_R1//;
	my $flag = getFlag("$outdir/$sample.filter");
	if (-f $flag ) {
		print STDERR "Skipped filtering of $sample\n";
		return;
	}
	
	if ( !$f2 ) {
		my $cmd = "$b -fastq $f";
		if ( $ext =~ /\.gz/ ) {
			$cmd= "gunzip -c $f | $b -fastq stdin";
		} 
		$cmd .= " -out_good $outdir/$stem -out_bad null $filter_param";
		print STDERR "Filtering $stem: $cmd\n";
		croak "Error: Failed to filter $f\n" if system($cmd);
		if ( -f "$outdir/$stem.fastq" ) {
			croak "Error: Failed to gzip $stem\n" if system("gzip -f $outdir/$stem.fastq");
		}
	} else {
		if ( $ext =~ /\.gz/ ) {
			my $fb = basename($f); $fb =~ s/\.gz//;
			my $fb2 = basename($f2); $fb2 =~ s/\.gz//;
			my $fq = "$outdir/" . basename($fb);
			my $fq2 = "$outdir/" . basename($fb2);
			$stem =~ s/[_\.]R[12]//;
			my $cmd = "gunzip -c $f > $fq && gunzip -c $f2 > $fq2";
			$cmd .=" && $b -fastq $fq -fastq2 $fq2 -out_good $outdir/$stem -out_bad null $filter_param";
			$cmd .=" && mv $outdir/${stem}_1.fastq $outdir/${stem}_R1.fastq";
			$cmd .=" && mv $outdir/${stem}_2.fastq $outdir/${stem}_R2.fastq";
			$cmd .=" && gzip -f $outdir/${stem}_R1.fastq";
			$cmd .=" && gzip -f $outdir/${stem}_R2.fastq";
			$cmd .=" && rm -f $outdir/${stem}_[12]_singletons.fastq";
			print STDERR "Filtering $stem: $cmd\n";
			croak "Error: Failed to filter $stem\n" if system($cmd);
		}
	}
	
	qx(touch $flag);
}
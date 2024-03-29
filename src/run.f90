! Copyright 2018 Warrick Ball & Bill Chaplin

! This file is part of the AsteroFLAG Artificial Dataset Generator v3 (AADG3).

! AADG3 is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.

! AADG3 is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.

! You should have received a copy of the GNU General Public License
! along with AADG3.  If not, see <https://www.gnu.org/licenses/>.

program AADG3

  use types, only: dp
  use math, only: PI, TWOPI, k_to_lm
  
  implicit none
  
  integer :: ierr, i, l, m
  integer, parameter :: ntype = 16
  integer :: nc(ntype), user_seed
  integer :: n_cadences, n_relax, n_fine
  real(dp), allocatable :: vtotal(:), v(:)
  real(dp) :: rho, tau, sig
  real(dp) :: inclination, cycle_period, cycle_phase, sdnu(ntype)
  real(dp) :: pcad, phicad, nsdsum, p(0:3), nuac
  real(dp) :: cadence, nsd(ntype), pvis(ntype), ptot
  real(dp), dimension(2000, ntype) :: fc, wc, pc, cs
  character(50) :: input_filename, modes_filename, rotation_filename, output_filename
  character(50) :: output_fmt
  logical :: add_granulation
  integer :: iounit
  integer :: n_seed
  integer, allocatable :: seed(:)
  logical :: verbose

  namelist /controls/ user_seed, n_relax, n_cadences, n_fine, cadence, &
       sig, rho, tau, inclination, cycle_period, cycle_phase, nuac, sdnu, p, &
       add_granulation, modes_filename, rotation_filename, &
       output_filename, output_fmt, verbose

  ! set some defaults for input file
  user_seed = 0
  cycle_period = 1d6
  cycle_phase = 0d0
  nuac = 0
  p = 0
  p(0) = 1
  sdnu = 0
  output_fmt = '(f16.7)'
  verbose = .false.

  ! these defaults should force user to choose values
  n_fine = -1
  n_relax = -1
  n_cadences = -1
  
  ierr = 0

  call parse_args

  if (verbose) then
     write(*,*) ''
     call show_version
     write(*,*) ''
  end if
  
  if (verbose) write(*,'(A)',advance='no') 'Checking command line arguments... '
  call check_args
  if (verbose) write(*,'(A)') 'Done.'

  if (verbose) write(*,'(A)',advance='no') 'Initialising random number generator... '
  if (user_seed == 0) then
     call random_seed
  elseif (user_seed > 0) then
     call random_seed(size=n_seed)
     allocate(seed(n_seed))
     seed(1) = user_seed
     do i = 2, n_seed
        seed(i) = user_seed + mod(i**2 + 14897, 1234)
     end do
     call random_seed(put=seed)
     deallocate(seed)
  else
     if (verbose) write(*,*) ''
     write(*,*) 'ERROR in run.f90: user_seed must be >= 0'
     stop 1
  endif
  
  allocate(vtotal(n_cadences))
  
  call random_number(vtotal)  ! warms up RNG
  vtotal = 0
  if (verbose) write(*,'(A)') 'Done.'

  
  if (verbose) write(*,'(A)',advance='no') 'Loading mode data... '
  call get_modes
  if (verbose) write(*,'(A)') 'Done.'
  
  ! Next, determine the variances for the correlated noise arrays
  ! this is buggy if angular degrees are missing because correlated
  ! noise won't be added if ncomp == 0
  ptot = sum(pvis)

  ! Calculate variances:
  nsd = sqrt(cadence/tau/n_fine)*sig*sqrt(pvis/ptot)
  nsdsum = sum(nsd**2)
  
  ! convert stellar cycle period and phase into multiples of cadence
  pcad = 2.0*cycle_period*86400.0*365.25/cadence
  phicad = 2.0*cycle_phase*86400.0*365.25/cadence

  ! main loop, to make overtones of each (l,m):
  if (verbose) write(*,'(A)') 'Computing oscillations... '
  if (verbose) write(*,'(3A6)') 'l', 'm', 'nc'
  
  !$OMP PARALLEL DO SCHEDULE(dynamic) PRIVATE(i,l,m,v) REDUCTION(+:vtotal)
  do i = 1, ntype
     allocate(v(n_cadences))
     call k_to_lm(i, l, m)
     ! if (verbose) write(*,'(I5,A4,I2)') i, ' of ', ntype
     if (verbose) write(*,'(4I6,A4,I2)') l, m, nc(i), i, ' of ', ntype
     call overtones(nc(i), nsd(i), sdnu(i), &
          fc(:,i), wc(:,i), pc(:,i), cs(:,i), v)
     vtotal = vtotal + v
     deallocate(v)
  end do
  !$OMP END PARALLEL DO
  
  if (verbose) write(*,'(A)') 'Finished computing oscillations.'

  ! Now output time series to disk:
  if (verbose) write(*,'(A)',advance='no') 'Saving output timeseries to disk... '
  ierr = 0
  open(newunit=iounit, file=output_filename, status='replace', iostat=ierr)
  if (ierr /= 0) then
     if (verbose) write(*,*) ''
     write(*,*) 'ERROR in AADG3 while opening ', output_filename
     stop
  end if
  write(iounit, output_fmt) (vtotal(i), i=1, n_cadences)
  close(iounit)
  if (verbose) write(*,'(A)') 'Done.'

  deallocate(vtotal)

contains
  
  subroutine get_modes
    use io, only: load_rotation, skip_comments
    use math, only: get_Elm, lm_to_k
    
    integer :: k, l, m, n
    real(dp) :: x, d1, d2, d3, d4
    real(dp) :: s(-2000:200,3,3)
    real(dp) :: Elm(0:3,0:3)
    integer :: iounit

    x = cos(inclination*TWOPI/360d0)

    ! fix visibilities of the individual components:
    ! Gizon & Solanki (2003), eq. (11)
    ! pvis(l,m) = V2(l)*E(l,m)
    ! k = l(l+1) + m + 1
    
    call get_Elm(inclination, 3, Elm)
    do l = 0, 3
       do m = -l, l
          call lm_to_k(l, m, k)
          pvis(k) = p(l)*Elm(l,abs(m))
       end do
    end do
    
    call load_rotation(rotation_filename, lbound(s, 1), s)

    ierr = 0
    open(newunit=iounit, file=modes_filename, status='old', iostat=ierr)
    if (ierr /= 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR in AADG3.get_modes while opening ', modes_filename
       stop
    end if

    nc = 0
    do
       call skip_comments(iounit, ierr)
       if (ierr /= 0) then
          ierr = 0
          exit
       end if
       
       read(iounit, *, iostat=ierr) l, n, d1, d2, d3, d4
       if (ierr /= 0) then
          if (verbose) write(*,*) ''
          write(*,*) 'WARNING in AADG3.get_modes: unexpected early exit while reading ', modes_filename
          exit
       end if

       do m = -l, l
          call lm_to_k(l, m, k)
          if ((pvis(k) > 1d-8) .and. (d3 > 1d-8)) then
             nc(k) = nc(k) + 1
             if (m == 0) then
                fc(nc(k), k) = d1
             else
                fc(nc(k), k) = d1 + m*s(n,l,abs(m))
             end if
             wc(nc(k), k) = d2
             pc(nc(k), k) = pvis(k)*d3
             cs(nc(k), k) = d4
          end if
          
       end do
    end do

    if (ierr > 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR in AADG3.get_modes while reading ', modes_filename
       stop
    end if
    
    close(iounit)

    return
    
  end subroutine get_modes

  
  subroutine overtones(ncomp, nsdi, sdnui, freqs, widths, powers, Bshifts, vout)
    
    use core, only: generate_kicks, laplace_solution
    
    integer, intent(in) :: ncomp
    real(dp), intent(in) :: nsdi, sdnui
    real(dp), intent(in), dimension(ncomp) :: freqs, widths, powers, Bshifts
    real(dp), dimension(n_cadences), intent(out) :: vout
    
    integer :: j
    real(dp) :: damp0, freq0
    ! real(dp) :: nuac
    real(dp), dimension(n_relax+n_cadences) :: ckick, ukick, kickthis
    real(dp), dimension(n_cadences) :: vi
    real(dp) :: dnu, dwid

    vi = 0
    vout = 0

    ckick = 0
    call generate_kicks(n_fine, cadence, tau, nsdi, ckick)

    ! loop over the overtones for this (l,|m|) value
    do j = 1, ncomp
       ukick = 0
       call generate_kicks(n_fine, cadence, tau, nsdi, ukick)
       
       freq0 = freqs(j)*cadence*1d-6
       damp0 = cadence*PI*1d-6*widths(j)
       ! Get shift factor for frequency:
       dnu = sdnui*Bshifts(j)*cadence*1d-6  ! activity cycle frequency shift
       ! ... and factor for width:
       dwid = (sdnui/0.40)*0.25  ! activity cycle width shift

       !   dwid = (sdnui)/0.40)*0.25*(1.0-dabs((fc(j,ic)/(1000.0*nuac))-2.90d0)/1.1d0)
       !   if ((fc(j,ic)/nuac) < 1800.0.or.((fc(j,ic)/nuac) > 4000.0) dwid = 0.0

       kickthis = rho*ckick + ukick*sqrt(1.0_dp - rho**2)

       call laplace_solution(n_cadences, n_relax, kickthis, freq0, damp0, &
            powers(j), dnu, dwid, pcad, phicad, vi)
       vout = vout + vi
    end do

    if (add_granulation) then
       vout = vout + ckick(n_relax+1:n_relax+n_cadences)
    end if

    return
    
  end subroutine overtones
  

  subroutine parse_args
    character(80) :: arg
    integer :: i
    
    call getarg(1, arg)
    if (arg == '-h' .or. arg == '--help') then
       call show_help
       stop
    else if (arg == '-V' .or. arg == '--version') then
       call show_version
       stop
    else if (arg == ' ') then
       call show_usage
       stop
    end if
    
    call getarg(1, input_filename)
    
    ! Get basic parameters from the information file:
    open(newunit=iounit, file=input_filename, status='old', iostat=ierr)
    
    if (ierr /= 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR in AADG3 while opening ', input_filename
       stop 1
    end if
    
    read(iounit, nml=controls, iostat=ierr)
    close(iounit)
    
    if (ierr /= 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR in AADG3 while reading ', input_filename
       write(*,*) 'the following runtime error may be informative'
       open(newunit=iounit, file=input_filename, status='old', iostat=ierr)
       read(iounit, nml=controls)
       stop 1
    end if

    ! loop over remaining command line arguments to get override input
    ! values
    i = 2
    call getarg(i, arg)
    do while (arg  /= ' ')
       ! write(*,*) i, arg
       
       ! integer options
       if (arg == '--user_seed' .or. arg == '--user-seed') then
          call get_int_arg(i, user_seed)
       else if (arg == '--n_relax' .or. arg == '--n-relax') then
          call get_int_arg(i, n_relax)
       else if (arg == '--n_cadences' .or. arg == '--n-cadences') then
          call get_int_arg(i, n_cadences)
       else if (arg == '--n_fine' .or. arg == '--n-fine') then
          call get_int_arg(i, n_fine)
       ! float options
       else if (arg == '--cadence') then
          call get_real_arg(i, cadence)
       else if (arg == '--sig') then
          call get_real_arg(i, sig)
       else if (arg == '--rho') then
          call get_real_arg(i, rho)
       else if (arg == '--tau') then
          call get_real_arg(i, tau)
       else if (arg == '--inclination') then
          call get_real_arg(i, inclination)
       else if (arg == '--cycle_period' .or. arg == '--cycle-period') then
          call get_real_arg(i, cycle_period)
       else if (arg == '--cycle_phase' .or. arg == '--cycle-phase') then
          call get_real_arg(i, cycle_phase)
       ! logical options
       else if (arg == '--add_granulation' .or. arg == '--add-granulation') then
          add_granulation = .true.
       else if (arg == '--no-add_granulation' .or. arg == '--no-add-granulation') then
          add_granulation = .false.
       else if (arg == '--verbose' .or. arg == '-v') then
          verbose = .true.
       else if (arg == '--no-verbose' .or. arg == '--quiet' .or. arg == '-q') then
          verbose = .false.
       ! string options
       else if (arg == '--modes_filename' .or. arg == '--modes-filename') then
          i = i + 1
          call getarg(i, modes_filename)
       else if (arg == '--rotation_filename' .or. arg == '--rotation-filename') then
          i = i + 1
          call getarg(i, rotation_filename)
       else if (arg == '--output_filename' .or. arg == '--output-filename' .or. arg == '-o') then
          i = i + 1
          call getarg(i, output_filename)
       else
          if (verbose) write(*,*) ''
          write(*,*) 'ERROR in AADG3 while parsing command-line arguments'
          write(*,*) 'argument ', trim(arg), ' is not valid'
          stop 1
       end if

       i = i + 1
       call getarg(i, arg)
    end do
    
  end subroutine parse_args


  subroutine get_int_arg(i, var)

    integer, intent(inout) :: i
    integer, intent(out) :: var
    character(80) :: arg
    
    i = i + 1
    call getarg(i, arg)
    read(arg, *, iostat=ierr) var
    if (ierr /= 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR in get_int_arg: could not parse string ', arg, 'as integer'
       stop 1
    end if

  end subroutine get_int_arg
  

  subroutine get_real_arg(i, var)

    integer, intent(inout) :: i
    real(dp), intent(out) :: var
    character(80) :: arg

    i = i + 1
    call getarg(i, arg)
    read(arg, *, iostat=ierr) var
    if (ierr /= 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR in get_real_arg: could not parse string ', arg, 'as real(dp)'
       stop 1
    end if

  end subroutine get_real_arg
  

  subroutine check_args
    
    if (inclination < 0 .or. inclination > 90) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR: inclination must be between 0 and 90 degrees'
       write(*,*) 'but got ', inclination
       stop 1
    end if

    if (rho < 0 .or. rho > 1) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR: rho must be between 0 and 1'
       write(*,*) 'but got ', rho
       stop 1
    end if

    call check_positive_float('sig', sig)
    call check_positive_float('rho', rho)
    call check_positive_float('tau', tau)
    call check_positive_float('cycle_period', cycle_period)
    call check_positive_float('cycle_phase', cycle_phase)
    
    call check_positive_int('n_fine', n_fine)
    call check_positive_int('n_relax', n_relax)
    call check_positive_int('n_cadences', n_cadences)
    
  end subroutine check_args


  subroutine check_positive_float(name, val)
    
    character(*) :: name
    real(dp) :: val

    if (val < 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR: ', name, ' must be positive'
       write(*,*) 'but got ', val
       stop 1
    end if
    
  end subroutine check_positive_float


  subroutine check_positive_int(name, val)
    
    character(*) :: name
    integer :: val

    if (val < 0) then
       if (verbose) write(*,*) ''
       write(*,*) 'ERROR: ', name, ' must be positive'
       write(*,*) 'but got ', val
       stop 1
    end if
    
  end subroutine check_positive_int
  
  
  subroutine show_help

    write(*,*)
    write(*,*) "asteroFLAG Artificial Dataset Generator 3 (AADG3)"
    write(*,*) "Copyright 2018 Warrick Ball & Bill Chaplin"
    write(*,*) "https://warrickball.github.io/AADG3"
    write(*,*)
    call show_usage
    write(*,*)
    write(*,*) 'Initial options (must be first argument):'
    write(*,*) '  -h, --help            show this help and exit'
    write(*,*) '  -V, --version         show version and exit'
    write(*,*) ''
    write(*,*) 'You can override any of the options in the input file by adding the option '
    write(*,*) 'preceded by `--` and followed by the desired value.  e.g. the argument '
    write(*,*) '`--n-cadences 1000` would override the parameter `n_cadences` in the input file '
    write(*,*) 'and replace it with 1000.  For logical options, either set the parameter with '
    write(*,*) '`--name` or unset it with --no-name`. e.g. `--no-add-granulation`.'
    write(*,*)

  end subroutine show_help


  subroutine show_usage

    write(*,*) 'usage: AADG3 [-h] [-V] <input file> [options]'
    
  end subroutine show_usage

  subroutine show_version

    write(*,*) 'AADG3 v3.0.1a'

  end subroutine show_version
  
end program AADG3

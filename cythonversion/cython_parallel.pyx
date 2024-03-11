"""
Basic Python Lebwohl-Lasher code.  Based on the paper 
P.A. Lebwohl and G. Lasher, Phys. Rev. A, 6, 426-429 (1972).
This version in 2D.

Run at the command line by typing:

python LebwohlLasher.py <ITERATIONS> <SIZE> <TEMPERATURE> <PLOTFLAG>

where:
  ITERATIONS = number of Monte Carlo steps, where 1MCS is when each cell
      has attempted a change once on average (i.e. SIZE*SIZE attempts)
  SIZE = side length of square lattice
  TEMPERATURE = reduced temperature in range 0.0 - 2.0.
  PLOTFLAG = 0 for no plot, 1 for energy plot and 2 for angle plot.
  
The initial configuration is set at random. The boundaries
are periodic throughout the simulation.  During the
time-stepping, an array containing two domains is used; these
domains alternate between old data and new data.

SH 16-Oct-23
"""
# Replace 'numpy_path' with the path where numpy is installed on system
cdef extern from "numpy/arrayobject.h" nogil:
    pass


import time
import datetime
import numpy as np
cimport numpy as np
import matplotlib.pyplot as plt
import matplotlib as mpl

import cython
from cython.parallel import prange,parallel

cimport openmp

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.cdivision(True)
#=======================================================================
cdef double[:,:] initdat(int nmax):
    """
    Arguments:
      nmax (int) = size of lattice to create (nmax,nmax).
    Description:
      Function to create and initialise the main data array that holds
      the lattice.  Will return a square lattice (size nmax x nmax)
	  initialised with random orientations in the range [0,2pi].
	Returns:
	  arr (float(nmax,nmax)) = array to hold lattice.
    """
    cdef double pi_2=2.0*np.pi # @@@ avoid repeated calculation
    cdef double[:,:] arr = np.random.random_sample((nmax,nmax))*pi_2
    return arr
#=======================================================================
cdef void plotdat(double[:,:] arr,int pflag,int nmax):
    """
    Arguments:
	  arr (float(nmax,nmax)) = array that contains lattice data;
	  pflag (int) = parameter to control plotting;
      nmax (int) = side length of square lattice.
    Description:
      Function to make a pretty plot of the data array.  Makes use of the
      quiver plot style in matplotlib.  Use pflag to control style:
        pflag = 0 for no plot (for scripted operation);
        pflag = 1 for energy plot;
        pflag = 2 for angles plot;
        pflag = 3 for black plot.
	  The angles plot uses a cyclic color map representing the range from
	  0 to pi.  The energy plot is normalised to the energy range of the
	  current frame.
	Returns:
      NULL
    """
    if pflag==0:
        return
    cdef:
        double[:, :] u = np.cos(arr)
        double[:, :] v = np.sin(arr)
        int[:] x = np.arange(nmax)
        int[:] y = np.arange(nmax)
        double[:, :] cols = np.zeros((nmax, nmax), dtype=np.double)
    if pflag==1: # colour the arrows according to energy
        mpl.rc('image', cmap='rainbow')
        
        for i in range(nmax):
            for j in range(nmax):
                 cols[i,j] = <double>one_energy(arr,i,j,nmax)
        norm = plt.Normalize(cols.min(), cols.max())
    elif pflag==2: # colour the arrows according to angle
        mpl.rc('image', cmap='hsv')
        cols = arr%np.pi
        norm = plt.Normalize(vmin=0, vmax=np.pi)
    else:
        mpl.rc('image', cmap='gist_gray')
        cols = np.zeros_like(arr)
        norm = plt.Normalize(vmin=0, vmax=1)

    quiveropts = dict(headlength=0,pivot='middle',headwidth=1,scale=1.1*nmax)
    fig, ax = plt.subplots()
    q = ax.quiver(x, y, u, v, cols,norm=norm, **quiveropts)
    ax.set_aspect('equal')
    plt.show()
#=======================================================================
cdef void savedat(double[:,:] arr,int nsteps,double Ts,runtime,double[:] ratio,double[:] energy,double[:] order,int nmax):
    """
    Arguments:
	  arr (float(nmax,nmax)) = array that contains lattice data;
	  nsteps (int) = number of Monte Carlo steps (MCS) performed;
	  Ts (float) = reduced temperature (range 0 to 2);
	  ratio (float(nsteps)) = array of acceptance ratios per MCS;
	  energy (float(nsteps)) = array of reduced energies per MCS;
	  order (float(nsteps)) = array of order parameters per MCS;
      nmax (int) = side length of square lattice to simulated.
    Description:
      Function to save the energy, order and acceptance ratio
      per Monte Carlo step to text file.  Also saves run data in the
      header.  Filenames are generated automatically based on
      date and time at beginning of execution.
	Returns:
	  NULL
    """
    # Create filename based on current date and time.
    current_datetime = datetime.datetime.now().strftime("%a-%d-%b-%Y-at-%I-%M-%S%p")
    filename = "LL-Output-{:s}.txt".format(current_datetime)
    FileOut = open(filename,"w")
    # Write a header with run parameters
    print("#=====================================================",file=FileOut)
    print("# File created:        {:s}".format(current_datetime),file=FileOut)
    print("# Size of lattice:     {:d}x{:d}".format(nmax,nmax),file=FileOut)
    print("# Number of MC steps:  {:d}".format(nsteps),file=FileOut)
    print("# Reduced temperature: {:5.3f}".format(Ts),file=FileOut)
    print("# Run time (s):        {:8.6f}".format(runtime),file=FileOut)
    print("#=====================================================",file=FileOut)
    print("# MC step:  Ratio:     Energy:   Order:",file=FileOut)
    print("#=====================================================",file=FileOut)
    # Write the columns of data
    cdef Py_ssize_t i
    for i in range(nsteps+1):
        print("   {:05d}    {:6.4f} {:12.4f}  {:6.4f} ".format(i,ratio[i],energy[i],order[i]),file=FileOut)
    FileOut.close()
#=======================================================================
# one_energy function is called many times, it's suitable to use numba to accelerate it

cdef double one_energy(double[:,:] arr,int ix,int iy,int nmax):
    """
    Arguments:
	  arr (float(nmax,nmax)) = array that contains lattice data;
	  ix (int) = x lattice coordinate of cell;
	  iy (int) = y lattice coordinate of cell;
      nmax (int) = side length of square lattice.
    Description:
      Function that computes the energy of a single cell of the
      lattice taking into account periodic boundaries.  Working with
      reduced energy (U/epsilon), equivalent to setting epsilon=1 in
      equation (1) in the project notes.
	Returns:
	  en (float) = reduced energy of cell.
    """
    cdef:
        double en = 0.0
        int ixp = (ix+1)%nmax # These are the coordinates
        int ixm = (ix-1)%nmax # of the neighbours
        int iyp = (iy+1)%nmax # with wraparound
        int iym = (iy-1)%nmax #
#
# Add together the 4 neighbour contributions
# to the energy
#
    cdef:
        double  ang1 = arr[ix,iy]-arr[ixp,iy]
        double  ang2 = arr[ix,iy]-arr[ixm,iy]
        double  ang3 = arr[ix,iy]-arr[ix,iyp]
        double  ang4 = arr[ix,iy]-arr[ix,iym]
        double  ang=np.cos(ang1)**2+np.cos(ang2)**2+np.cos(ang3)**2+np.cos(ang4)**2
    en += 0.5- 1.5*ang
    
    return en
#=======================================================================

cdef double all_energy(double[:,:] arr,int nmax,int threads):
    """
    Arguments:
	  arr (float(nmax,nmax)) = array that contains lattice data;
      nmax (int) = side length of square lattice.
    Description:
      Function to compute the energy of the entire lattice. Output
      is in reduced units (U/epsilon).
	Returns:
	  enall (float) = reduced energy of lattice.
    """
    cdef double enall = 0.0
    cdef Py_ssize_t i
    cdef Py_ssize_t j
    for i in prange(nmax,nogil=True,num_threads=threads):
        for j in range(nmax):
            with gil:
                enall += one_energy(arr,i,j,nmax)
    return enall
#=======================================================================

cdef double get_order(double[:,:] arr,int nmax,int threads):
    """
    Arguments:
	  arr (float(nmax,nmax)) = array that contains lattice data;
      nmax (int) = side length of square lattice.
    Description:
      Function to calculate the order parameter of a lattice
      using the Q tensor approach, as in equation (3) of the
      project notes.  Function returns S_lattice = max(eigenvalues(Q_ab)).
	Returns:
	  max(eigenvalues(Qab)) (float) = order parameter for lattice.
    """
    cdef:
        np.ndarray Qab = np.zeros((3,3))
        double[:,:] delta = np.eye(3,3)
    
    
    
    #
    # Generate a 3D unit vector for each cell (i,j) and
    # put it in a (3,i,j) array.
    #
    lab = np.vstack((np.cos(arr),np.sin(arr),np.zeros_like(arr))).reshape(3,nmax,nmax)
    cdef Py_ssize_t a
    cdef Py_ssize_t b
    cdef Py_ssize_t i
    cdef Py_ssize_t j
    for a in range(3):
        for b in range(3):
            for i in range(nmax):
                for j in range(nmax):
                    Qab[a,b] += 3*lab[a,i,j]*lab[b,i,j] - delta[a,b]
    cdef double factor = 2 * nmax * nmax
    """
    cdef Py_ssize_t m
    cdef Py_ssize_t n
    for m in range(Qab.shape[0]):
        for n in range(Qab.shape[1]):
            Qab[m, n] = <double>(Qab[m, n] / factor)
    """
    Qab = Qab/factor
    eigenvalues,eigenvectors = np.linalg.eig(Qab)
    return eigenvalues.max()
#=======================================================================

cdef double MC_step(double[:,:] arr, double Ts, int nmax, int threads):
    """
    Arguments:
      arr (float(nmax,nmax)) = array that contains lattice data;
      Ts (float) = reduced temperature (range 0 to 2);
      nmax (int) = side length of square lattice.
    Description:
      Function to perform one MC step, which consists of an average
      of 1 attempted change per lattice site.  Working with reduced
      temperature Ts = kT/epsilon.  Function returns the acceptance
      ratio for information.  This is the fraction of attempted changes
      that are successful.  Generally aim to keep this around 0.5 for
      efficient simulation.
    Returns:
      accept/(nmax**2) (float) = acceptance ratio for current MCS.
    """
    #
    # Pre-compute some random numbers.  This is faster than
    # using lots of individual calls.  "scale" sets the width
    # of the distribution for the angle changes - increases
    # with temperature.
    cdef:
        double scale=0.1+Ts
        int accept = 0
        long [:,:] xran = np.random.randint(0,high=nmax, size=(nmax,nmax))
        long [:,:] yran = np.random.randint(0,high=nmax, size=(nmax,nmax))
        double[:,:] aran = np.random.normal(scale=scale, size=(nmax,nmax))
    cdef Py_ssize_t i
    cdef Py_ssize_t j
    cdef int ix, iy
    cdef double en0, en1, ang, boltz
    for i in prange(nmax,nogil=True,num_threads=threads):
        for j in range(nmax):
            ix = xran[i,j]
            iy = yran[i,j]
            ang = aran[i,j]
            with gil:
                en0 = one_energy(arr,ix,iy,nmax)
            arr[ix,iy] += ang
            with gil:
                en1 = one_energy(arr,ix,iy,nmax)
            if en1<=en0:
                accept += 1
            else:
            # Now apply the Monte Carlo test - compare
            # exp( -(E_new - E_old) / T* ) >= rand(0,1)
                with gil:
                    boltz = np.exp( -(en1 - en0) / Ts )

                    if boltz >= np.random.uniform(0.0,1.0):
                        accept += 1
                    else:
                        arr[ix,iy] -= ang
    return accept/(nmax*nmax)
#=======================================================================
def main(str program, int nsteps,int nmax,double temp,int pflag,int threads):
    """
    Arguments:
	  program (string) = the name of the program;
	  nsteps (int) = number of Monte Carlo steps (MCS) to perform;
      nmax (int) = side length of square lattice to simulate;
	  temp (float) = reduced temperature (range 0 to 2);
	  pflag (int) = a flag to control plotting;
      threads(int) = the number of threads.
    Description:
      This is the main function running the Lebwohl-Lasher simulation.
    Returns:
      NULL
    """
    # Create and initialise lattice
    cdef double[:,:] lattice = initdat(nmax)
    # Plot initial frame of lattice
    plotdat(lattice,pflag,nmax)
    # Create arrays to store energy, acceptance ratio and order parameter
    cdef double[:] energy = np.zeros(nsteps+1,dtype=np.double)
    cdef double[:] ratio = np.zeros(nsteps+1,dtype=np.double)
    cdef double[:] order = np.zeros(nsteps+1,dtype=np.double)
    # Set initial values in arrays
    energy[0] = all_energy(lattice,nmax,threads)
    ratio[0] = 0.5 # ideal value
    order[0] = get_order(lattice,nmax,threads)

    # Begin doing and timing some MC steps.
    #initial = time.time()
    initial = openmp.omp_get_wtime()
    cdef Py_ssize_t it
    for it in range(1,nsteps+1):
        ratio[it] = MC_step(lattice,temp,nmax,threads)
        energy[it] = all_energy(lattice,nmax,threads)
        order[it] = get_order(lattice,nmax,threads)
    final =openmp.omp_get_wtime()
    #final = time.time()
    runtime = final-initial
    
    # Final outputs
    print("{}: Size: {:d}, Steps: {:d}, T*: {:5.3f}: Order: {:5.3f}, Time: {:8.6f} s, threads:{:d}".format(program, nmax,nsteps,temp,order[nsteps-1],runtime,threads))
    # Plot final frame of lattice and generate output file
    savedat(lattice,nsteps,temp,runtime,ratio,energy,order,nmax)
    plotdat(lattice,pflag,nmax)
#=======================================================================
# Main part of program, getting command line arguments and calling
# main simulation function.
#
"""
if __name__ == '__main__':
    if int(len(sys.argv)) == 5:
        PROGNAME = sys.argv[0]
        ITERATIONS = int(sys.argv[1])
        SIZE = int(sys.argv[2])
        TEMPERATURE = float(sys.argv[3])
        PLOTFLAG = int(sys.argv[4])
        main(PROGNAME, ITERATIONS, SIZE, TEMPERATURE, PLOTFLAG)
    else:
        print("Usage: python {} <ITERATIONS> <SIZE> <TEMPERATURE> <PLOTFLAG>".format(sys.argv[0]))
#=======================================================================
"""
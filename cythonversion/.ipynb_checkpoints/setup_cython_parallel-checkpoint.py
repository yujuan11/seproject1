"""
from distutils.core import setup
from Cython.Build import cythonize
import numpy  # Make sure numpy is installed (pip install numpy)

setup(ext_modules=cythonize("ll_cython.pyx",annotate=True))

"""

from setuptools import setup, Extension
from Cython.Build import cythonize
import numpy  # Make sure numpy is installed (pip install numpy)

extensions = [
    Extension(
        "cython_parallel",
        sources=["cython_parallel.pyx"],
        include_dirs=[numpy.get_include()],  # This line adds the NumPy include path
        extra_compile_args =['-fopenmp'] ,
        extra_link_args =['-fopenmp'] ,
    ),
]

setup(
    name='cython_parallel',
    ext_modules=cythonize(extensions,annotate=True)
    # Other setup options
)




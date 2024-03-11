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
        "cython_nochange",
        sources=["cython_nochange.pyx"],
        include_dirs=[numpy.get_include()],  # This line adds the NumPy include path
        # Add other compiler flags and options if needed
    ),
]

setup(
    ext_modules=cythonize(extensions,annotate=True)
    # Other setup options
)



